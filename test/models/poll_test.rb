require "test_helper"

class PollTest < ActiveSupport::TestCase
  test "population enum round-trips every value" do
    Poll.populations.each_key do |value|
      poll = Poll.new(population: value)
      assert_equal value, poll.population
    end
  end

  test "population defaults to unknown" do
    assert_equal "unknown", Poll.new.population
  end

  test "entry_mode enum round-trips every value" do
    Poll.entry_modes.each_key do |value|
      poll = Poll.new(entry_mode: value)
      assert_equal value, poll.entry_mode
    end
  end

  test "generic_ballot? is true when race is nil" do
    assert polls(:generic_ballot_poll).generic_ballot?
  end

  test "generic_ballot? is false when race is present" do
    assert_not polls(:maine_poll_one).generic_ballot?
  end

  test "for_generic_ballot scope returns only polls with no race" do
    assert_includes Poll.for_generic_ballot, polls(:generic_ballot_poll)
    assert_not_includes Poll.for_generic_ballot, polls(:maine_poll_one)
  end

  test "recent_first orders by field_end descending" do
    ordered = Poll.where(id: [ polls(:maine_poll_one).id, polls(:maine_poll_two).id ]).recent_first
    assert_equal [ polls(:maine_poll_two), polls(:maine_poll_one) ], ordered.to_a
  end

  test "requires source_url" do
    poll = Poll.new(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 7, 1), dedup_digest: "x")
    assert_not poll.valid?
    assert_includes poll.errors[:source_url], "can't be blank"
  end

  test "requires field_end" do
    poll = Poll.new(pollster: pollsters(:beacon_polling), source_url: "https://example.com/x", dedup_digest: "x")
    assert_not poll.valid?
    assert_includes poll.errors[:field_end], "can't be blank"
  end

  test "field_end must be on or after field_start" do
    poll = Poll.new(
      pollster: pollsters(:beacon_polling), source_url: "https://example.com/x", dedup_digest: "x",
      field_start: Date.new(2026, 7, 10), field_end: Date.new(2026, 7, 5)
    )
    assert_not poll.valid?
    assert_includes poll.errors[:field_end], "must be on or after field_start"
  end

  test "field_end equal to field_start is valid and saves" do
    poll = Poll.new(
      pollster: pollsters(:beacon_polling), race: races(:senate_maine), source_url: "https://example.com/x",
      dedup_digest: "unique-equal-dates", entry_mode: :manual,
      field_start: Date.new(2026, 7, 10), field_end: Date.new(2026, 7, 10)
    )
    assert poll.save, poll.errors.full_messages.to_sentence
  end

  test "requires dedup_digest" do
    poll = Poll.new(pollster: pollsters(:beacon_polling), source_url: "https://example.com/x", field_end: Date.new(2026, 7, 1))
    assert_not poll.valid?
    assert_includes poll.errors[:dedup_digest], "can't be blank"
  end

  test "unique index prevents two polls with the same dedup_digest" do
    duplicate = Poll.new(
      pollster: pollsters(:beacon_polling), source_url: "https://example.com/dup",
      field_end: Date.new(2026, 7, 1), entry_mode: :scraped,
      dedup_digest: polls(:maine_poll_one).dedup_digest
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) do
        duplicate.save(validate: false)
      end
    end
  end

  test "compute_digest is deterministic for the same inputs" do
    args = {
      pollster_slug: "beacon-polling", race_id: 1,
      field_start: Date.new(2026, 7, 1), field_end: Date.new(2026, 7, 5),
      results: [ { party: "dem", pct: 47.5 }, { party: "rep", pct: 44.0 } ]
    }
    assert_equal Poll.compute_digest(**args), Poll.compute_digest(**args)
  end

  test "compute_digest is independent of result order" do
    base = { pollster_slug: "beacon-polling", race_id: 1, field_start: Date.new(2026, 7, 1), field_end: Date.new(2026, 7, 5) }
    forward = Poll.compute_digest(**base, results: [ { party: "dem", pct: 47.5 }, { party: "rep", pct: 44.0 } ])
    reversed = Poll.compute_digest(**base, results: [ { party: "rep", pct: 44.0 }, { party: "dem", pct: 47.5 } ])
    assert_equal forward, reversed
  end

  test "compute_digest rounds pct to 1 decimal place" do
    base = { pollster_slug: "beacon-polling", race_id: 1, field_start: Date.new(2026, 7, 1), field_end: Date.new(2026, 7, 5) }
    a = Poll.compute_digest(**base, results: [ { party: "dem", pct: 47.441 } ])
    b = Poll.compute_digest(**base, results: [ { party: "dem", pct: 47.449 } ])
    assert_equal a, b
  end

  test "compute_digest differs when a meaningful input differs" do
    base = { race_id: 1, field_start: Date.new(2026, 7, 1), field_end: Date.new(2026, 7, 5), results: [ { party: "dem", pct: 47.5 } ] }
    a = Poll.compute_digest(pollster_slug: "beacon-polling", **base)
    b = Poll.compute_digest(pollster_slug: "cardinal-research", **base)
    assert_not_equal a, b
  end

  test "compute_digest handles a nil race_id for generic-ballot polls" do
    digest = Poll.compute_digest(
      pollster_slug: "delta-metrics", race_id: nil,
      field_start: Date.new(2026, 7, 25), field_end: Date.new(2026, 7, 28),
      results: [ { party: "dem", pct: 46.5 }, { party: "rep", pct: 44.5 } ]
    )
    assert_kind_of String, digest
    assert_equal 64, digest.length
  end

  # matchup_key is the normalised form the averager compares on;
  # #matchup_label is what a reader should see, taken from the labels the
  # source page actually used.
  test "matchup_label reads back the contest as the page wrote it" do
    poll = create_poll(
      pollster: pollsters(:beacon_polling), race: races(:house_ny_17), field_end: Date.new(2026, 7, 1),
      results: { dem: 51.0, rep: 45.0 }, matchup_key: "conley vs lawler",
      raw_payload: { "columns" => { "Poll source" => "Beacon", "Mike Lawler (R)" => "45%",
                                    "Cait Conley (D)" => "51%", "Undecided" => "4%" } }
    )

    assert_equal "Cait Conley (D) vs Mike Lawler (R)", poll.matchup_label
  end

  test "matchup_label falls back to the key when the cell map cannot supply labels" do
    poll = create_poll(pollster: pollsters(:beacon_polling), race: races(:house_ny_17),
                       field_end: Date.new(2026, 7, 1), results: { dem: 51.0, rep: 45.0 },
                       matchup_key: "conley vs lawler")

    assert_equal "Conley vs Lawler", poll.matchup_label
  end

  test "a poll with no matchup has no label" do
    assert_nil polls(:maine_poll_one).matchup_label
  end
end
