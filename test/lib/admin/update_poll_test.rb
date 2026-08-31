require "test_helper"

class Admin::UpdatePollTest < ActiveSupport::TestCase
  setup do
    @race = races(:senate_maine)
    @dem = candidates(:maine_dem)
    @rep = candidates(:maine_rep)
    @poll = Ingest::RecordPoll.call(
      { pollster_name: "Harbor Analytics", race: @race, field_start: Date.new(2026, 8, 1),
        field_end: Date.new(2026, 8, 4), sample_size: 700, population: :lv,
        source_url: "https://example.com/harbor-1" },
      results: [ { party: :dem, pct: 48.0, candidate: @dem }, { party: :rep, pct: 44.5, candidate: @rep } ]
    ).poll
  end

  def attributes(**overrides)
    {
      pollster_name: "Harbor Analytics", race_id: @race.id,
      field_start: Date.new(2026, 8, 1), field_end: Date.new(2026, 8, 4),
      sample_size: 700, population: :lv, source_url: "https://example.com/harbor-1"
    }.merge(overrides)
  end

  def results
    [ { party: :dem, pct: 48.0 }, { party: :rep, pct: 44.5 } ]
  end

  test "updates the poll's fields in place" do
    result = Admin::UpdatePoll.call(@poll, attributes(sponsor: "Portland Press"), results: results)

    assert result.updated?
    @poll.reload
    assert_equal "Portland Press", @poll.sponsor
  end

  test "recomputes the digest when dates change" do
    original_digest = @poll.dedup_digest

    result = Admin::UpdatePoll.call(@poll, attributes(field_end: Date.new(2026, 8, 5)), results: results)

    assert result.updated?
    @poll.reload
    assert_not_equal original_digest, @poll.dedup_digest
    assert_equal Date.new(2026, 8, 5), @poll.field_end
  end

  test "recomputes the digest when the pollster changes" do
    result = Admin::UpdatePoll.call(@poll, attributes(pollster_name: "Beacon Polling"), results: results)

    assert result.updated?
    @poll.reload
    assert_equal pollsters(:beacon_polling), @poll.pollster
  end

  test "recomputes the digest when results change" do
    result = Admin::UpdatePoll.call(@poll, attributes, results: [ { party: :dem, pct: 50.0 }, { party: :rep, pct: 42.0 } ])

    assert result.updated?
    @poll.reload
    assert_equal [ 42.0, 50.0 ], @poll.poll_results.map(&:pct).sort
  end

  test "replaces poll_results rather than accumulating them" do
    # Starts with 2 results (dem+rep); editing down to 1 must net -1, not +1
    # (which is what accumulating the old 2 plus the new 1 would produce).
    assert_difference "PollResult.count", -1 do
      Admin::UpdatePoll.call(@poll, attributes, results: [ { party: :dem, pct: 50.0 } ])
    end

    @poll.reload
    assert_equal 1, @poll.poll_results.count
    assert_equal "dem", @poll.poll_results.first.party
  end

  test "reassigning candidates on results persists them" do
    Admin::UpdatePoll.call(@poll, attributes, results: [ { party: :dem, pct: 48.0, candidate: @dem } ])

    @poll.reload
    assert_equal @dem, @poll.poll_results.find_by(party: :dem).candidate
  end

  test "guards against colliding with a DIFFERENT poll after the edit, and leaves the row untouched" do
    other = Ingest::RecordPoll.call(
      { pollster_name: "Cardinal Research", race: @race, field_start: Date.new(2026, 7, 20),
        field_end: Date.new(2026, 7, 24), source_url: "https://example.com/cardinal-1" },
      results: [ { party: :dem, pct: 46.0 }, { party: :rep, pct: 45.0 } ]
    ).poll
    original_digest = @poll.dedup_digest

    result = Admin::UpdatePoll.call(
      @poll,
      attributes(pollster_name: "Cardinal Research", field_start: Date.new(2026, 7, 20), field_end: Date.new(2026, 7, 24)),
      results: [ { party: :dem, pct: 46.0 }, { party: :rep, pct: 45.0 } ]
    )

    assert result.duplicate?
    assert_equal other, result.existing
    @poll.reload
    assert_equal original_digest, @poll.dedup_digest, "the poll being edited must not be half-modified by a rejected edit"
    assert_equal "Harbor Analytics", @poll.pollster.name
  end

  test "editing a poll back to its own current values is not a collision with itself" do
    result = Admin::UpdatePoll.call(@poll, attributes, results: results)
    assert result.updated?
  end

  test "touches the race when a race-attached field changes" do
    @race.update_column(:updated_at, 1.day.ago)

    assert_changes -> { @race.reload.updated_at } do
      Admin::UpdatePoll.call(@poll, attributes(sponsor: "New sponsor"), results: results)
    end
  end

  test "touches both the old and new race when the poll's race is reassigned" do
    other_race = races(:senate_florida_special)
    @race.update_column(:updated_at, 1.day.ago)
    other_race.update_column(:updated_at, 1.day.ago)

    Admin::UpdatePoll.call(@poll, attributes(race_id: other_race.id), results: results)

    assert @race.reload.updated_at > 23.hours.ago
    assert other_race.reload.updated_at > 23.hours.ago
  end

  test "touches nothing when the poll is a generic-ballot poll with no race before or after" do
    generic = Ingest::RecordPoll.call(
      { pollster_name: "Delta Metrics", field_end: Date.new(2026, 8, 1), source_url: "https://example.com/delta-1" },
      results: [ { party: :dem, pct: 46.0 }, { party: :rep, pct: 44.0 } ]
    ).poll

    assert_no_difference -> { Race.maximum(:updated_at) } do
      Admin::UpdatePoll.call(generic, attributes(race_id: nil, pollster_name: "Delta Metrics"), results: [ { party: :dem, pct: 47.0 }, { party: :rep, pct: 44.0 } ])
    end
  end

  test "rejects a blank source_url without persisting anything" do
    result = Admin::UpdatePoll.call(@poll, attributes(source_url: ""), results: results)

    assert result.invalid?
    assert_match(/source_url/, result.message)
    @poll.reload
    assert_equal "https://example.com/harbor-1", @poll.source_url
  end

  test "rejects a result with a nonsense percentage" do
    result = Admin::UpdatePoll.call(@poll, attributes, results: [ { party: :dem, pct: 140.0 } ])
    assert result.invalid?
  end

  # Finding 2 (review fix): the controller no longer coerces a typed
  # percentage with #to_f before it reaches here (see Admin::PercentValue),
  # so a non-numeric value arrives as the original String — this proves
  # UpdatePoll's own is_a?(Numeric) check rejects that String on its own
  # terms, independent of what the controller does with it.
  test "rejects a result whose percentage is a non-numeric String, leaving the poll unchanged" do
    original_pct = @poll.poll_results.find_by(party: :dem).pct

    result = Admin::UpdatePoll.call(@poll, attributes, results: [ { party: :dem, pct: "N/A" }, { party: :rep, pct: 44.5 } ])

    assert result.invalid?
    assert_equal original_pct, @poll.reload.poll_results.find_by(party: :dem).pct
  end

  test "editing a feed poll keeps its salted digest, so twin questions stay distinct" do
    poll = create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 7, 10),
                       race: races(:senate_maine), entry_mode: :nyt,
                       nyt_question_id: "q-lv", results: { dem: 48.0, rep: 44.0 })
    twin = create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 7, 10),
                       race: races(:senate_maine), entry_mode: :nyt,
                       nyt_question_id: "q-rv", results: { dem: 48.0, rep: 44.0 })

    result = Admin::UpdatePoll.call(poll, {
      pollster_name: poll.pollster.name, race_id: poll.race_id,
      field_start: poll.field_start, field_end: poll.field_end,
      sample_size: poll.sample_size, population: poll.population,
      source_url: poll.source_url, sponsor: "Edited Sponsor"
    }, results: [ { party: :dem, pct: 48.0 }, { party: :rep, pct: 44.0 } ])

    assert result.updated?, result.message.to_s
    assert_not_equal poll.reload.dedup_digest, twin.reload.dedup_digest
  end
end
