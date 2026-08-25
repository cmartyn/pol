require "test_helper"

class RacesHelperTest < ActionView::TestCase
  # earlier_matchup?(race, matchup_key) — a group's heading gets the
  # "polled before the field was set" tag when the key names, for any
  # party, a surname not among the race's *current* candidates of that
  # party. Both sides go through Ingest::PollTableParser.surname, which is
  # what makes a suffix/accent spelling variant agree rather than false-flag.

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
end
