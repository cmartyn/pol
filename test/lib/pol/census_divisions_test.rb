require "test_helper"

class Pol::CensusDivisionsTest < ActiveSupport::TestCase
  test "there are exactly nine divisions and none of them is empty" do
    assert_equal 9, Pol::CensusDivisions.names.size
    assert_equal 9, Pol::CensusDivisions::STATES_BY_DIVISION.size

    Pol::CensusDivisions::STATES_BY_DIVISION.each do |division, states|
      assert_predicate states, :any?, "#{division} has no states"
    end
  end

  # The table is the Census Bureau's, so the test is against the Census
  # Bureau's own counts: 6 + 3 + 5 + 7 + 9 + 4 + 4 + 8 + 5 = 51.
  test "every division holds the states the Census Bureau puts in it" do
    assert_equal({
      "New England" => 6, "Middle Atlantic" => 3, "East North Central" => 5,
      "West North Central" => 7, "South Atlantic" => 9, "East South Central" => 4,
      "West South Central" => 4, "Mountain" => 8, "Pacific" => 5
    }, Pol::CensusDivisions::STATES_BY_DIVISION.transform_values(&:size))
  end

  test "all fifty states are covered, each exactly once" do
    codes = Pol::CensusDivisions.state_codes

    assert_equal codes.uniq, codes, "a state cannot be in two divisions"
    assert_equal 51, codes.size, "50 states plus DC"
    # Race::STATE_NAMES is the independent list — the one the site renders
    # from — so the two cannot drift without this failing.
    assert_equal Race::STATE_NAMES.keys.sort, codes.sort
  end

  test "a state resolves to its division" do
    assert_equal "New England", Pol::CensusDivisions.for("ME")
    assert_equal "Pacific", Pol::CensusDivisions.for("AK")
    assert_equal "South Atlantic", Pol::CensusDivisions.for("GA")
    assert_equal "West South Central", Pol::CensusDivisions.for("TX")
    assert_equal "East North Central", Pol::CensusDivisions.for("MI")
  end

  # DC is in the table because the Census puts it in the South Atlantic. It has
  # no Senate seat and no voting House district, so it never reaches the
  # simulator — but a table that disagreed with its source would be the kind of
  # small silent edit this whole file exists to prevent.
  test "DC is in the South Atlantic, where the Census puts it, and has no race" do
    assert_equal "South Atlantic", Pol::CensusDivisions.for("DC")
    assert_equal 0, Race.where(state: "DC").count
  end

  test "every state with a race on the board has a division" do
    states = Race.where(office: %i[senate house]).distinct.pluck(:state)

    assert_predicate states, :any?
    states.each { |state| assert_predicate Pol::CensusDivisions.for(state), :present? }
  end

  # A territory, a typo or a nil would otherwise take no regional or state
  # error and quietly narrow the seat distribution.
  test "an unmapped state raises rather than resolving to nothing" do
    [ "PR", "GU", "ZZ", "", nil ].each do |state|
      error = assert_raises(KeyError) { Pol::CensusDivisions.for(state) }
      assert_match(/no census division/, error.message)
    end
  end

  test "the tables are frozen, so nothing can edit the map at runtime" do
    assert_predicate Pol::CensusDivisions::STATES_BY_DIVISION, :frozen?
    assert_predicate Pol::CensusDivisions::DIVISION_BY_STATE, :frozen?
  end
end
