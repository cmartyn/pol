require "minitest/autorun"
module ElectionNight
end
require_relative "../../../app/lib/election_night/outstanding_votes"

class ElectionNightOutstandingVotesTest < Minitest::Test
  def unit(key, dem, rep, other = 0)
    { "unit_key" => key, "dem_votes" => dem, "rep_votes" => rep, "other_votes" => other,
      "total_votes" => dem + rep + other, "source_id" => "official" }
  end

  def pair(current, historical)
    [ current, historical, historical["dem_votes"] + historical["rep_votes"] ]
  end

  def estimate(matched, mu: 0, **options)
    ElectionNight::OutstandingVotes.new(matched: matched, race_prior: { "race_key" => "NC-S", "mu" => mu }, **options).call
  end

  def balanced_history
    [ unit("URBAN", 80_000, 20_000), unit("RURAL", 20_000, 80_000) ]
  end

  def test_zero_returns_project_candidate_votes_but_supply_no_margin_measurement
    result = estimate(balanced_history.map { |history| pair(unit(history["unit_key"], 0, 0), history) })
    assert_equal 150_000, result["remaining_votes"]
    assert_equal 0, result["counted_fraction"]
    assert_equal 0, result["represented_fraction"]
    assert_nil result["measurement"]
    assert_equal "all_candidate_votes", result["vote_denominator"]
    assert_equal "assumption_based_scenarios", result["interval_kind"]
    assert_equal "historical_anchor_with_unresolved_tail", result["point_kind"]
    assert_operator result["remaining_votes_low"], :>, 0
    assert_operator result["remaining_votes_high"], :>, result["remaining_votes"]
  end

  def test_reporting_urban_geography_first_does_not_create_a_democratic_swing
    urban, rural = balanced_history
    result = estimate([ pair(unit("URBAN", 40_000, 10_000), urban), pair(unit("RURAL", 0, 0), rural) ])
    assert_in_delta 0, result.dig("measurement", "observed_margin"), 1e-10
    assert_equal 0.5, result["represented_fraction"]
    assert_equal 100_000, result["remaining_votes"]
    assert_operator result.dig("measurement", "sigma"), :>=, 4
    assert_operator result["counted_fraction_low"], :<, result["counted_fraction"]
    assert_operator result["counted_fraction_high"], :<, 1
  end

  def test_margin_denominator_includes_minor_candidates_but_eligibility_count_is_separate
    result = estimate([ pair(unit("A", 30_000, 15_000, 5_000), unit("A", 60_000, 30_000, 10_000)) ], mu: 30)
    assert_equal 50_000, result["counted_votes"]
    assert_equal 45_000, result["counted_two_party_votes"]
    assert_in_delta 30, result.dig("measurement", "observed_margin"), 1e-10
    assert_equal "all_candidate_votes", result["margin_denominator"]
  end

  def test_bounded_geographic_alignment_preserves_prior_with_polarized_counties
    urban = unit("URBAN", 95_000, 5_000)
    rural = unit("RURAL", 5_000, 95_000)
    result = estimate([ pair(unit("URBAN", 50_000, 0), urban), pair(unit("RURAL", 0, 0), rural) ], mu: 30)
    assert_in_delta 30, result.dig("measurement", "observed_margin"), 1e-9
  end

  def test_validated_midterm_anchors_change_each_county_not_a_single_national_multiplier
    rows = balanced_history.map { |history| pair(unit(history["unit_key"], 0, 0), history) }
    result = estimate(rows, midterm_totals: { "URBAN" => 40_000, "RURAL" => 80_000 })
    assert_equal 120_000, result["projected_total_votes"]
    assert_equal 2, result["midterm_anchored_units"]
    assert_equal 0, result["fallback_units"]
    assert_equal({ "RURAL" => 80_000, "URBAN" => 40_000 }, result["units"].to_h { |row| [ row["unit_key"], row["turnout_anchor"] ] })
    mixed = estimate(rows, midterm_totals: { "URBAN" => 40_000 })
    assert_equal 115_000, mixed["projected_total_votes"]
    assert_equal 1, mixed["fallback_units"]
  end

  def test_turnout_overshoot_expands_uncertainty_and_never_establishes_completion
    history = unit("A", 60_000, 40_000)
    typical = estimate([ pair(unit("A", 45_000, 30_000), history) ], mu: 20)
    overshoot = estimate([ pair(unit("A", 90_000, 60_000), history) ], mu: 20)
    assert_equal 1, overshoot["turnout_overshoot_units"]
    assert_operator overshoot["remaining_votes"], :>, 15_000
    assert_operator overshoot["remaining_votes_low"], :>=, 0
    assert_operator overshoot["counted_fraction"], :<, 0.92
    assert_operator overshoot["counted_fraction_high"], :<, 1
    assert_operator overshoot["remaining_votes_high"] - overshoot["remaining_votes_low"], :>, typical["remaining_votes_high"] - typical["remaining_votes_low"]
    assert_operator overshoot.dig("measurement", "sigma"), :>=, 4
  end

  def test_geographically_missing_returns_retain_more_reporting_order_uncertainty
    urban, rural = balanced_history
    partial = estimate([ pair(unit("URBAN", 40_000, 10_000), urban), pair(unit("RURAL", 0, 0), rural) ], draws: 1024)
    broad = estimate([ pair(unit("URBAN", 20_000, 5_000), urban), pair(unit("RURAL", 5_000, 20_000), rural) ], draws: 1024)
    assert_operator partial.dig("measurement", "sigma"), :>, broad.dig("measurement", "sigma")
    assert_equal partial["counted_votes"], broad["counted_votes"]
  end

  def test_shared_turnout_uncertainty_does_not_vanish_with_many_counties
    rows = 100.times.map { |n| pair(unit(n.to_s, 0, 0), unit(n.to_s, 6000, 4000)) }
    result = estimate(rows)
    relative_width = (result["projected_total_votes_high"] - result["projected_total_votes_low"]) / result["projected_total_votes"]
    assert_operator relative_width, :>, 0.4
  end

  def test_identical_inputs_are_deterministic_and_provider_forecasts_are_ignored
    rows = balanced_history.map { |history| pair(unit(history["unit_key"], 8000, 2000), history) }
    expected = estimate(rows)
    assert_equal expected, estimate(rows.reverse)
    rows.each { |current, _, _| current.merge!("percent_reporting" => 100, "expected_votes" => 1, "complete" => true, "p_dem_win" => 1.0) }
    assert_equal expected, estimate(rows)
    different_seed = estimate(rows, seed: 1)
    assert_equal expected.dig("measurement", "observed_margin"), different_seed.dig("measurement", "observed_margin")
  end

  def test_rejects_missing_inconsistent_or_mismatched_geography_and_counts
    history = unit("A", 6000, 4000)
    current = unit("A", 3000, 2000)
    assert_raises(ArgumentError) { estimate([]) }
    assert_raises(ArgumentError) { estimate([ pair(current, history), pair(current, history) ]) }
    assert_raises(ArgumentError) { estimate([ pair(current, history.merge("unit_key" => "B")) ]) }
    assert_raises(ArgumentError) { estimate([ pair(current.merge("total_votes" => 1), history) ]) }
    assert_raises(ArgumentError) { estimate([ pair(current.merge("dem_votes" => nil), history) ]) }
    assert_raises(ArgumentError) { estimate([ [ current, history, 999 ] ]) }
    assert_raises(ArgumentError) { estimate([ pair(current, history) ], midterm_totals: { "B" => 5000 }) }
    assert_raises(ArgumentError) { estimate([ pair(current, history) ], midterm_totals: { "A" => 0 }) }
    assert_raises(ArgumentError) { estimate([ pair(current, history) ], mu: Float::NAN) }
    assert_raises(ArgumentError) { estimate([ pair(unit("A", 10**100, 0), history) ]) }
  end

  def test_extreme_overshoot_stays_finite_with_positive_remaining_range
    result = estimate([ pair(unit("A", 9_000_000, 6_000_000), unit("A", 60, 40)) ], mu: 20)
    %w[projected_total_votes remaining_votes_low remaining_votes_high counted_fraction].each { |key| assert result[key].finite? }
    assert_operator result["remaining_votes_low"], :>, 0
    assert_operator result["counted_fraction_high"], :<, 1
  end
end
