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

    side_a, _side_b = Site::RaceSides.for(candidates)

    assert_equal "ind", side_a
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
