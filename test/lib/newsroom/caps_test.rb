require "test_helper"

class Newsroom::CapsTest < ActiveSupport::TestCase
  setup do
    @race = races(:senate_maine)
    @other_race = races(:senate_florida_special)
    # The fixture dispatch is dated August 2; these tests are about "today",
    # so it has to stay out of the way unless a test puts it there.
    dispatches(:maine_poll_reaction).update!(published_at: 30.days.ago)
  end

  def publish(race: @race, kind: :poll_reaction, at: Time.current, cited: [])
    Dispatch.create!(
      kind: kind, race: race, status: :published, published_at: at,
      headline: "Something happened", body_markdown: "Body.", cited_poll_ids: cited
    )
  end

  test "nothing blocks a first piece of the day" do
    assert_nil Newsroom::Caps.blocking(kind: :poll_reaction, race: @race, poll_ids: [ 1 ])
  end

  test "the per-race cap counts the race's dispatches published today" do
    limit = Pol::Params.fetch!(:newsroom, :max_dispatches_per_race_per_day)
    (limit - 1).times { publish }

    assert_nil Newsroom::Caps.blocking(kind: :poll_reaction, race: @race)

    publish
    reason, detail = Newsroom::Caps.blocking(kind: :poll_reaction, race: @race)
    assert_equal :cap_reached, reason
    assert_match(/#{limit} dispatches already published for senate-me-2026 today/, detail)
  end

  test "one race using up its budget does not silence another" do
    Pol::Params.fetch!(:newsroom, :max_dispatches_per_race_per_day).times { publish }

    assert Newsroom::Caps.blocking(kind: :poll_reaction, race: @race)
    assert_nil Newsroom::Caps.blocking(kind: :poll_reaction, race: @other_race)
  end

  test "the global cap counts everything published today, whatever race it was about" do
    with_params(newsroom: { max_dispatches_per_day: 2 }) do
      publish
      publish(race: @other_race)

      reason, detail = Newsroom::Caps.blocking(kind: :daily_brief)
      assert_equal :cap_reached, reason
      assert_match(/2 dispatches already published today; the daily cap is 2/, detail)
    end
  end

  # The caps are per America/New_York day, because that is the day the site's
  # readers and its 07:00 brief are on. Cutting them on UTC days would move
  # the boundary into the middle of the American evening — a race could get
  # its next three pieces at 8pm Eastern, four hours after its last three.
  test "the day boundary is Eastern midnight, not UTC midnight" do
    with_params(newsroom: { max_dispatches_per_day: 1 }) do
      # 03:30 UTC on August 12 is 23:30 Eastern on August 11: still yesterday.
      publish(at: Time.utc(2026, 8, 12, 3, 30))

      travel_to Time.utc(2026, 8, 12, 3, 45) do
        assert Newsroom::Caps.blocking(kind: :daily_brief), "same Eastern day: the cap applies"
      end

      # 04:30 UTC is 00:30 Eastern: a new day, and a fresh budget, even though
      # the two dispatches are an hour apart.
      travel_to Time.utc(2026, 8, 12, 4, 30) do
        assert_nil Newsroom::Caps.blocking(kind: :daily_brief), "new Eastern day: the budget resets"
      end
    end
  end

  test "a poll already cited by a published dispatch is not news twice" do
    published = publish(cited: [ 41, 42 ])

    reason, detail = Newsroom::Caps.blocking(kind: :poll_reaction, race: @race, poll_ids: [ 42, 43 ])
    assert_equal :duplicate, reason
    assert_match(/dispatch ##{published.id} already cites \[42\]/, detail)
  end

  test "polls nobody has written about yet are not duplicates" do
    publish(cited: [ 41 ])

    assert_nil Newsroom::Caps.blocking(kind: :poll_reaction, race: @race, poll_ids: [ 42, 43 ])
  end

  # Retraction gives back the day's budget — that piece is not on the site —
  # but it must not hand the polls back to be written up again. An editor who
  # pulls a reaction and gets a regenerated one an hour later cannot win.
  test "a retracted dispatch does not release its polls" do
    retracted = publish(cited: [ 42 ])
    retracted.update!(status: :retracted)

    reason, detail = Newsroom::Caps.blocking(kind: :poll_reaction, race: @race, poll_ids: [ 42 ])
    assert_equal :duplicate, reason
    assert_match(/##{retracted.id} \(retracted\) already cites \[42\]/, detail)
  end

  test "a retracted dispatch does give back its share of the day's cap" do
    with_params(newsroom: { max_dispatches_per_day: 1 }) do
      publish(cited: [ 42 ]).update!(status: :retracted)

      assert_nil Newsroom::Caps.blocking(kind: :daily_brief)
    end
  end

  # The movement cooldown is not one number: it is a ceiling far from the
  # election, a floor in its final days, and a ramp between them
  # (Newsroom::Caps.movement_cooldown_days). These tests pin dates rather than
  # reading the clock, so the suite means the same thing in August as in
  # November.
  FAR_OUT = Time.utc(2026, 8, 5, 16)        # 90 days before 2026-11-03; noon Eastern (EDT)
  ELECTION_EVE = Time.utc(2026, 11, 2, 17)  # noon Eastern (EST by then)

  def cooldown_max
    Pol::Params.fetch!(:newsroom, :movement_note_cooldown_max_days)
  end

  def cooldown_min
    Pol::Params.fetch!(:newsroom, :movement_note_cooldown_min_days)
  end

  # F3 fix: a retracted movement note used to fall out of the cooldown scope
  # entirely (it was `Dispatch.published.movement_note`), so the very next
  # 2-hourly run would regenerate the piece an editor had just pulled — the
  # delta that prompted it hadn't gone anywhere. The cooldown must survive
  # retraction even though the day caps above deliberately do not.
  test "a retracted movement note still holds its cooldown, so a later run does not regenerate it" do
    travel_to FAR_OUT do
      retracted = publish(kind: :movement_note, at: 1.day.ago)
      retracted.update!(status: :retracted)

      reason, detail = Newsroom::Caps.blocking(kind: :movement_note, race: @race)
      assert_equal :cap_reached, reason
      assert_match(/##{retracted.id}/, detail)
    end
  end

  test "movement notes are capped to one per race per cooldown window" do
    travel_to FAR_OUT do
      recent = publish(kind: :movement_note, at: (cooldown_max - 1).days.ago)

      reason, detail = Newsroom::Caps.blocking(kind: :movement_note, race: @race)
      assert_equal :cap_reached, reason
      assert_match(/movement note for senate-me-2026 was published/, detail)
      assert_match(/##{recent.id}/, detail)
      assert_match(/the cooldown is #{cooldown_max} days, 90 days out from the election/, detail)
    end
  end

  test "once the cooldown has passed the same race may move again" do
    travel_to FAR_OUT do
      publish(kind: :movement_note, at: (cooldown_max + 1).days.ago)

      assert_nil Newsroom::Caps.blocking(kind: :movement_note, race: @race)
    end
  end

  test "far from the election the cooldown is its ceiling" do
    travel_to(FAR_OUT) { assert_equal cooldown_max, Newsroom::Caps.movement_cooldown_days }
  end

  # "Start it at five days now": mid-September, seven weeks out, is still the
  # summer setting. The ramp begins after this.
  test "seven weeks out the cooldown is still its ceiling" do
    travel_to(Time.utc(2026, 9, 12, 16)) { assert_equal cooldown_max, Newsroom::Caps.movement_cooldown_days }
  end

  test "on the eve of the election the cooldown is its floor" do
    travel_to(ELECTION_EVE) { assert_equal cooldown_min, Newsroom::Caps.movement_cooldown_days }
  end

  test "after election day the cooldown holds at the floor rather than falling to zero" do
    travel_to(Time.utc(2026, 11, 10, 17)) { assert_equal cooldown_min, Newsroom::Caps.movement_cooldown_days }
  end

  # The floor is a day, not nothing: on election eve a note from this morning
  # still holds the race until tomorrow — and the skip says so in the singular.
  test "on election eve a note from this morning still blocks, because the floor is a day rather than nothing" do
    travel_to ELECTION_EVE do
      publish(kind: :movement_note, at: 6.hours.ago)

      reason, detail = Newsroom::Caps.blocking(kind: :movement_note, race: @race)
      assert_equal :cap_reached, reason
      assert_match(/1 day out from the election/, detail)
      assert_match(/the cooldown is #{cooldown_min} day,/, detail)
    end
  end

  # Whatever shape the ramp takes: it may only shorten as the election nears,
  # it stays inside its bounds in whole days, and it is a ramp rather than a
  # cliff — at least one setting lies between the ceiling and the floor.
  test "the cooldown only ever shortens as election day approaches, in whole days within its bounds" do
    election = Pol::Params.fetch!(:election, :date).to_date
    settings = 120.downto(0).map do |days_out|
      noon = (election - days_out).in_time_zone(Newsroom::ZONE) + 12.hours
      Newsroom::Caps.movement_cooldown_days(noon)
    end

    settings.each { |days| assert_kind_of Integer, days }
    assert_equal settings.sort.reverse, settings, "the cooldown lengthened somewhere on the way to election day"
    assert_equal cooldown_max, settings.first
    assert_equal cooldown_min, settings.last
    assert_operator (settings.uniq - [ cooldown_max, cooldown_min ]).size, :>=, 1, "a cliff, not a ramp"
  end

  test "days to the election are counted in Eastern calendar days" do
    # 02:00 UTC on November 3 is still 10pm on November 2 in New York.
    assert_equal 1, Newsroom::Caps.days_to_election(Time.utc(2026, 11, 3, 2))
    assert_equal 0, Newsroom::Caps.days_to_election(Time.utc(2026, 11, 3, 5))
  end

  test "a note three days old blocks in August but not in the final days, once the cooldown has ramped down" do
    travel_to FAR_OUT do
      publish(kind: :movement_note, at: 3.days.ago)
      assert Newsroom::Caps.blocking(kind: :movement_note, race: @race), "ninety days out the cooldown is days long"
    end

    travel_to ELECTION_EVE do
      publish(kind: :movement_note, at: 3.days.ago)
      assert_nil Newsroom::Caps.blocking(kind: :movement_note, race: @race), "on election eve it is a day"
    end
  end

  test "the cooldown is a movement-note rule, not a poll-reaction one" do
    publish(kind: :movement_note, at: 1.day.ago)

    assert_nil Newsroom::Caps.blocking(kind: :poll_reaction, race: @race)
  end

  test "the widest cap is reported first, so the detail explains the real reason" do
    with_params(newsroom: { max_dispatches_per_day: 1 }) do
      publish(race: @other_race, cited: [ 42 ])

      _reason, detail = Newsroom::Caps.blocking(kind: :poll_reaction, race: @race, poll_ids: [ 42 ])
      assert_match(/the daily cap is 1/, detail)
    end
  end
end
