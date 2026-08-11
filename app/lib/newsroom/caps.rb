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

    # A race that drifts a little every day is one story, not seven.
    def movement_cooldown(kind, race, now)
      return nil unless kind.to_sym == :movement_note && race

      days = Pol::Params.fetch!(:newsroom, :movement_note_cooldown_days)
      previous = Dispatch.published.movement_note
                         .where(race_id: race.id)
                         .where(published_at: (now - days.days)..now)
                         .recent_first.first
      return nil unless previous

      [ :cap_reached,
        "a movement note for #{race.slug} was published #{previous.published_at.to_date} " \
        "(##{previous.id}); the cooldown is #{days} days" ]
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
