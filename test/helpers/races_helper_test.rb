require "test_helper"

class RacesHelperTest < ActionView::TestCase
  # earlier_matchup?(race, matchup_key) — a group's heading gets the
  # "polled before the field was set" tag when the key names, for a party
  # the race actually holds candidates of, a surname not among that
  # party's *current* candidates. A party the race has zero candidates of
  # never contributes to staleness. Both sides go through
  # Ingest::PollTableParser.surname, which is what makes a suffix/accent
  # spelling variant agree rather than false-flag.

  test "false when the key names every party's current candidate" do
    race = races(:house_ny_17)
    key = Ingest::Matchup.key([ "Casey Nolan (D)", "Drew Halloran (R)" ])

    refute earlier_matchup?(race, key)
  end

  test "true when the key names a surname not among the race's current candidates for a party" do
    race = races(:house_ny_17)
    key = Ingest::Matchup.key([ "Pat Jones (D)", "Drew Halloran (R)" ])

    assert earlier_matchup?(race, key)
  end

  test "false when the key names a party the race holds no candidates of, even with the other parties matching" do
    race = races(:house_ny_17)
    key = Ingest::Matchup.key([ "Casey Nolan (D)", "Drew Halloran (R)", "Sam Rivera (L)" ])

    refute earlier_matchup?(race, key)
  end

  test "false for a race with no candidates, even given a key naming nobody on the race" do
    race = races(:senate_florida_special)
    assert_empty race.candidates
    key = Ingest::Matchup.key([ "Pat Jones (D)", "Drew Halloran (R)" ])

    refute earlier_matchup?(race, key)
  end

  test "false for a nil matchup key" do
    race = races(:house_ny_17)

    refute earlier_matchup?(race, nil)
  end

  test "normalizes a suffix/spelling variant through PollTableParser.surname before comparing" do
    race = races(:house_ny_17)
    key = Ingest::Matchup.key([ "Casey Nolan (D)", "Drew Halloran Jr. (R)" ])

    refute earlier_matchup?(race, key)
  end

  # A generic-ballot poll has no race, so no candidates to take its sides
  # from — but Site::RaceSides already answers dem/rep for an empty field,
  # which is the right answer for a poll whose whole question is which party.
  # Handling nil here means every caller gets race-less polls for free rather
  # than each surface growing its own dem-minus-rep branch.
  test "race_sides answers dem and rep for no race at all" do
    assert_equal %w[dem rep], race_sides(nil)
  end

  test "poll_margin measures a generic-ballot poll dem minus rep" do
    poll = polls(:generic_ballot_poll) # Dem 46.5, Rep 44.5

    assert_equal({ label: "D+2.0", party: "dem" }, poll_margin(poll, nil))
  end

  test "poll_margin reports no margin for a poll that asked about only one party" do
    poll = create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 8, 1), results: { dem: 46.0 })

    assert_nil poll_margin(poll, nil)
  end
end
