require "test_helper"

class Ingest::RecordPollTest < ActiveSupport::TestCase
  setup do
    @race = races(:senate_maine)
    @dem = candidates(:maine_dem)
    @rep = candidates(:maine_rep)
  end

  def attributes(**overrides)
    {
      pollster_name: "Harbor Analytics",
      race: @race,
      sponsor: "Portland Press",
      field_start: Date.new(2026, 8, 1),
      field_end: Date.new(2026, 8, 4),
      sample_size: 700,
      population: :lv,
      source_url: "https://en.wikipedia.org/wiki/Test#Polling",
      raw_payload: { "columns" => { "Poll source" => "Harbor Analytics" } }
    }.merge(overrides)
  end

  def results
    [ { party: :dem, pct: 48.0, candidate: @dem }, { party: :rep, pct: 44.5, candidate: @rep } ]
  end

  test "creates the poll, its results and the pollster in one go" do
    assert_difference [ "Poll.count", "Pollster.count" ], 1 do
      assert_difference "PollResult.count", 2 do
        @result = Ingest::RecordPoll.call(attributes, results: results)
      end
    end

    poll = @result.poll
    assert @result.created?
    assert_equal "harbor-analytics", poll.pollster.slug
    assert_equal "Harbor Analytics", poll.pollster.name
    assert_equal @race, poll.race
    assert_equal "Portland Press", poll.sponsor
    assert_equal 700, poll.sample_size
    assert_equal "lv", poll.population
    assert_equal "scraped", poll.entry_mode
    assert_equal [ @dem, @rep ], poll.poll_results.order(:party).map(&:candidate)
    assert_equal "Harbor Analytics", poll.raw_payload.dig("columns", "Poll source")
  end

  test "computes the digest the same way Poll does" do
    poll = Ingest::RecordPoll.call(attributes, results: results).poll

    assert_equal Poll.compute_digest(
      pollster_slug: "harbor-analytics", race_id: @race.id,
      field_start: Date.new(2026, 8, 1), field_end: Date.new(2026, 8, 4),
      results: [ { party: "dem", pct: 48.0 }, { party: "rep", pct: 44.5 } ]
    ), poll.dedup_digest
  end

  test "reuses an existing pollster rather than making a near-duplicate" do
    existing = pollsters(:beacon_polling)

    assert_no_difference "Pollster.count" do
      result = Ingest::RecordPoll.call(attributes(pollster_name: "beacon  polling!"), results: results)
      assert_equal existing, result.poll.pollster
    end
  end

  test "the same poll a second time is a duplicate, not a second row" do
    Ingest::RecordPoll.call(attributes, results: results)

    assert_no_difference [ "Poll.count", "PollResult.count" ] do
      @second = Ingest::RecordPoll.call(attributes, results: results)
    end

    assert @second.duplicate?
    assert_nil @second.poll
  end

  test "result order does not change the digest, so a reordered row is still a duplicate" do
    Ingest::RecordPoll.call(attributes, results: results)

    assert_no_difference "Poll.count" do
      assert Ingest::RecordPoll.call(attributes, results: results.reverse).duplicate?
    end
  end

  test "the unique index catches a duplicate that slipped past the exists? check" do
    Ingest::RecordPoll.call(attributes, results: results)

    # Simulates the race where another worker inserts the same digest between
    # our read and our write: the read says "not there", the index says "yes it is".
    assert_no_difference [ "Poll.count", "PollResult.count" ] do
      stubbing(Poll, :exists?, false) do
        @result = Ingest::RecordPoll.call(attributes, results: results)
      end
    end

    assert @result.duplicate?
  end

  test "rejects a row with no pollster, and writes nothing" do
    assert_no_difference [ "Poll.count", "PollResult.count", "Pollster.count" ] do
      @result = Ingest::RecordPoll.call(attributes(pollster_name: " "), results: results)
    end

    assert @result.invalid?
    assert_match(/pollster name/, @result.message)
  end

  test "rejects rows missing a source URL, a field end date, or any result" do
    { source_url: nil, field_end: nil }.each do |key, value|
      result = Ingest::RecordPoll.call(attributes(key => value), results: results)
      assert result.invalid?, "expected #{key} => #{value.inspect} to be rejected"
    end

    assert Ingest::RecordPoll.call(attributes, results: []).invalid?
  end

  test "rejects a result whose party or percentage is nonsense" do
    [
      [ { party: :whig, pct: 40.0 } ],
      [ { party: :dem, pct: "forty" } ],
      [ { party: :dem, pct: 140.0 } ],
      [ { party: :dem, pct: -1.0 } ]
    ].each do |bad|
      assert Ingest::RecordPoll.call(attributes, results: bad).invalid?, "expected #{bad.inspect} to be rejected"
    end
  end

  test "an invalid row leaves no orphan results behind" do
    assert_no_difference [ "Poll.count", "PollResult.count" ] do
      # A poll the model itself refuses: field_end before field_start.
      @result = Ingest::RecordPoll.call(
        attributes(field_start: Date.new(2026, 8, 10), field_end: Date.new(2026, 8, 1)), results: results
      )
    end

    assert @result.invalid?
    assert_match(/field end/i, @result.message)
  end

  test "a generic-ballot poll has no race and no candidates" do
    result = Ingest::RecordPoll.call(
      attributes(race: nil), results: [ { party: :dem, pct: 47.0 }, { party: :rep, pct: 43.0 } ]
    )

    assert result.created?
    assert result.poll.generic_ballot?
    assert_equal [ nil, nil ], result.poll.poll_results.map(&:candidate)
  end

  test "the entry mode is whatever the caller says it is" do
    result = Ingest::RecordPoll.call(attributes, results: results, entry_mode: :manual)

    assert_equal "manual", result.poll.entry_mode
  end
end
