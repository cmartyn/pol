module Newsroom
  # The rate limits that stand in for an editor. An autonomous newsroom with a
  # bug — a scrape that re-creates the same polls, a run that flaps a
  # probability across the movement threshold — fails by publishing, so the
  # caps are checked immediately before every piece is written, against what is
  # actually on the page rather than against a counter this process is keeping.
  #
  # Days are America/New_York days (Newsroom::ZONE): the site's readers and the
  # 07:00 brief are on that clock, so "three a day for one race" has to mean
  # three between two Eastern midnights, not between two UTC ones.
  module Caps
    module_function

    # nil when the piece may be written, otherwise [reason, detail] ready for
    # NewsroomSkip. Checked in order of scope: the whole board's daily budget,
    # then this race's, then whether we have already covered these polls.
    def blocking(kind:, race: nil, poll_ids: [], now: Time.current)
      global_cap(now) || race_cap(race, now) || movement_cooldown(kind, race, now) || duplicate(race, poll_ids)
    end

    # The Eastern calendar day containing `now`, as a UTC-comparable range.
    def day_range(now = Time.current)
      day = now.in_time_zone(Newsroom::ZONE)
      day.beginning_of_day..day.end_of_day
    end

    def published_today(now = Time.current)
      Dispatch.published.where(published_at: day_range(now))
    end

    def global_cap(now)
      limit = Pol::Params.fetch!(:newsroom, :max_dispatches_per_day)
      count = published_today(now).count
      return nil if count < limit

      [ :cap_reached, "#{count} dispatches already published today; the daily cap is #{limit}" ]
    end

    # Counts every published dispatch for the race today, not only the kind
    # about to be written: the parameter is a budget for how much this site
    # may say about one race in one day, and three poll reactions plus a
    # movement note is four pieces about the same race whatever they are called.
    def race_cap(race, now)
      return nil unless race

      limit = Pol::Params.fetch!(:newsroom, :max_dispatches_per_race_per_day)
      count = published_today(now).where(race_id: race.id).count
      return nil if count < limit

      [ :cap_reached, "#{count} dispatches already published for #{race.slug} today; the cap is #{limit}" ]
    end

    # A race that drifts a little every day is one story, not seven. Unlike
    # the day caps above, this scope is deliberately NOT limited to
    # .published: a movement note an editor retracted is still the reason the
    # newsroom should stay quiet about this race's drift for the rest of the
    # window. Scoping to .published here would let the very next run
    # regenerate the note the editor just pulled — movement notes carry no
    # poll_ids, so the duplicate guard below can't catch that the way it
    # catches a re-scraped poll reaction; this cooldown is the only guard
    # they have.
    def movement_cooldown(kind, race, now)
      return nil unless kind.to_sym == :movement_note && race

      days = movement_cooldown_days(now)
      previous = Dispatch.movement_note
                         .where(race_id: race.id)
                         .where(published_at: (now - days.days)..now)
                         .recent_first.first
      return nil unless previous

      out = days_to_election(now)
      [ :cap_reached,
        "a movement note for #{race.slug} was published #{previous.published_at.to_date} " \
        "(##{previous.id}); the cooldown is #{days} #{'day'.pluralize(days)}, " \
        "#{out} #{'day'.pluralize(out)} out from the election" ]
    end

    # How many whole days a race stays quiet after a movement note, on the day
    # `now` falls in. Not one number: a ceiling far from the election, a floor
    # in its final days, and a ramp between them, all read from
    # newsroom.movement_note_cooldown_{max,min,scale}_days — the same idea as
    # Forecast::Simulator#time_multiplier, which widens the forecast's error by
    # days to election. A summer race is one story a week; in the final
    # stretch, when polls land daily, movement earns a note far sooner. A short
    # cooldown cannot re-tell one move, because Newsroom::Movement measures a
    # race the newsroom has written up from that note's run, not from last week.
    #
    # clamp(ceil(days_to_election / scale), min, max): at a scale of 8 the
    # ceiling holds until forty days out, then the cooldown loses a day every
    # eight days and sits at the floor through the final week and after.
    # Rounded up rather than to nearest, so each step keeps the longer
    # cooldown until the day it is fully earned.
    def movement_cooldown_days(now = Time.current)
      max = Pol::Params.fetch!(:newsroom, :movement_note_cooldown_max_days)
      min = Pol::Params.fetch!(:newsroom, :movement_note_cooldown_min_days)
      scale = Pol::Params.fetch!(:newsroom, :movement_note_cooldown_scale_days)

      days_to_election(now).fdiv(scale).ceil.clamp(min, max)
    end

    # Whole Eastern calendar days from the day `now` falls in to election day,
    # floored at zero like Forecast::Simulator#time_multiplier: the ramp has
    # nowhere further to go once the election has happened.
    def days_to_election(now = Time.current)
      election = Pol::Params.fetch!(:election, :date).to_date
      [ (election - now.in_time_zone(Newsroom::ZONE).to_date).to_i, 0 ].max
    end

    # The reason ingestion can safely re-present a poll: if anything already
    # cites it, the story has been told.
    #
    # Retracted dispatches count here, unlike in the day caps above. A
    # retraction should give the day's budget back — that piece isn't on the
    # site — but it must not hand the polls back to the newsroom to write up
    # again. An editor who pulls a reaction and gets an automatically
    # regenerated one an hour later has no way to win.
    def duplicate(race, poll_ids)
      ids = Array(poll_ids)
      return nil if ids.empty?

      existing = Dispatch.citing_any(ids)
      existing = existing.where(race_id: race.id) if race
      first = existing.recent_first.first
      return nil unless first

      [ :duplicate,
        "dispatch ##{first.id}#{' (retracted)' if first.retracted?} already cites " \
        "#{(first.cited_poll_ids & ids).inspect}" ]
    end
  end
end
