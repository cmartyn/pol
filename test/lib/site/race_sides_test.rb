require "test_helper"

class Site::RaceSidesTest < ActiveSupport::TestCase
  test "a standard two-party race is dem vs rep" do
    side_a, side_b = Site::RaceSides.for(races(:house_ny_17).candidates)

    assert_equal "dem", side_a
    assert_equal "rep", side_b
  end

  test "a race with a minor-party candidate still puts the Democrat on side_a" do
    # senate_maine's fixture candidates are a Democrat, a Republican and an
    # independent — the independent must not bump the real Democrat off
    # side_a just because it's iterated.
    side_a, side_b = Site::RaceSides.for(races(:senate_maine).candidates)

    assert_equal "dem", side_a
    assert_equal "rep", side_b
  end

  test "no Democrat on the ballot puts the independent on side_a, per the three 2026 cases" do
    candidates = [
      Candidate.new(id: 1, party: "rep", name: "Incumbent Republican"),
      Candidate.new(id: 2, party: "ind", name: "Challenger Independent")
    ]

    side_a, side_b = Site::RaceSides.for(candidates)

    assert_equal "ind", side_a
    assert_equal "rep", side_b
  end

  test "with two non-major candidates, the lowest id wins side_a" do
    candidates = [
      Candidate.new(id: 1, party: "rep"),
      Candidate.new(id: 3, party: "other"),
      Candidate.new(id: 2, party: "ind")
    ]

    side_a, side_b = Site::RaceSides.for(candidates)

    assert_equal "ind", side_a
    # A Republican is still on this ballot, so side_b stays "rep" — the
    # minor-candidate fallback is only for side_a here.
    assert_equal "rep", side_b
  end

  test "an independent beats a lower-id minor-party candidate for side_a, matching the engine's tie-break" do
    # Forecast::RaceModel#top_minor_candidate sorts minor candidates by
    # [party == "ind" ? 0 : 1, id] — an independent always wins the slot over
    # another minor party regardless of id. The previous test above doesn't
    # discriminate this rule from a plain `.min_by(&:id)` (its independent
    # already has the lower id); this one does: "other" has the lower id and
    # must still lose to "ind".
    candidates = [
      Candidate.new(id: 1, party: "other", name: "Minor Party Candidate"),
      Candidate.new(id: 2, party: "ind", name: "Independent Candidate")
    ]

    side_a, side_b = Site::RaceSides.for(candidates)

    assert_equal "ind", side_a
    # Neither major party is on this ballot at all, so side_b has to fall
    # back to a minor candidate too — F1: it must be the OTHER one, not a
    # re-pick of whichever candidate side_a already claimed.
    assert_equal "other", side_b
  end

  # F1: app/lib/site/race_sides.rb:26 used to read `side_b = rep ? "rep" :
  # "rep"` — no fallback at all, so a race with no Republican on the ballot
  # was mislabeled "rep" regardless of who was actually running. This is the
  # simplest reproduction: a Democrat and an independent, no Republican.
  test "no Republican on the ballot: side_b falls back to the independent instead of a bare 'rep' label" do
    candidates = [
      Candidate.new(id: 1, party: "dem", name: "Ada Dean"),
      Candidate.new(id: 2, party: "ind", name: "Ty Loner")
    ]

    side_a, side_b = Site::RaceSides.for(candidates)

    assert_equal "dem", side_a
    assert_equal "ind", side_b
  end

  test "no candidates at all falls back to the generic dem/rep pair (unsettled or unseeded House races)" do
    side_a, side_b = Site::RaceSides.for([])

    assert_equal "dem", side_a
    assert_equal "rep", side_b
  end

  test "accepts a loaded relation, not just an array" do
    side_a, side_b = Site::RaceSides.for(races(:senate_maine).candidates.to_a)

    assert_equal "dem", side_a
    assert_equal "rep", side_b
  end
end
