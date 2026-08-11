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

  test "a retracted dispatch releases its polls" do
    publish(cited: [ 42 ]).update!(status: :retracted)

    assert_nil Newsroom::Caps.blocking(kind: :poll_reaction, race: @race, poll_ids: [ 42 ])
  end

  test "movement notes are capped to one per race per cooldown window" do
    days = Pol::Params.fetch!(:newsroom, :movement_note_cooldown_days)
    recent = publish(kind: :movement_note, at: (days - 1).days.ago)

    reason, detail = Newsroom::Caps.blocking(kind: :movement_note, race: @race)
    assert_equal :cap_reached, reason
    assert_match(/movement note for senate-me-2026 was published/, detail)
    assert_match(/##{recent.id}/, detail)
  end

  test "once the cooldown has passed the same race may move again" do
    days = Pol::Params.fetch!(:newsroom, :movement_note_cooldown_days)
    publish(kind: :movement_note, at: (days + 1).days.ago)

    assert_nil Newsroom::Caps.blocking(kind: :movement_note, race: @race)
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
