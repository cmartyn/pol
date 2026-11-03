require "minitest/autorun"
require_relative "../../../app/lib/election_night/nowcast"

class ElectionNight::NowcastTest < Minitest::Test
  def test_no_evidence_preserves_analytic_prior_and_unobserved_status
    result = run_model([ race("NC-S", mu: 3, sigma: 3) ], [], n_sims: 40_000)
    output = result.fetch("races").first
    expected_sigma = Math.sqrt(1 + 4 + 9)
    expected_probability = 0.5 * (1 + Math.erf(3 / (expected_sigma * Math.sqrt(2))))

    assert_equal 3.0, output.fetch("mean_margin")
    assert_in_delta expected_probability, output.fetch("p_dem_win"), 0.01
    assert_in_delta 3 - 1.644854 * expected_sigma, output.fetch("percentiles").fetch("5"), 0.15
    assert_equal "prior_only", output.fetch("status")
    refute output.fetch("direct_observation")
    assert_equal 0, result.fetch("diagnostics").fetch("observed_races")
  end

  def test_single_measurement_matches_closed_form_posterior
    # Prior total variance 1 national + 4 state + 9 race = 14. With a
    # measurement variance of 4, the mean is 14/18*y and variance 14*4/18.
    result = run_model([ race("NC-S", sigma: 3) ], [ observation("NC-S", margin: 2, sigma: 2) ], n_sims: 40_000)
    output = result.fetch("races").first
    mean = 14.0 / 18 * 2
    sigma = Math.sqrt(14.0 * 4 / 18)
    expected_probability = 0.5 * (1 + Math.erf(mean / (sigma * Math.sqrt(2))))

    assert_in_delta mean, output.fetch("mean_margin"), 1e-12
    assert_in_delta expected_probability, output.fetch("p_dem_win"), 0.01
    assert_in_delta mean - 1.644854 * sigma, output.fetch("percentiles").fetch("5"), 0.1
    assert_in_delta 2.0 / 18, result.dig("diagnostics", "shared_effects", "national"), 1e-12
    assert_equal "returns_updated", output.fetch("status")
    assert_equal [ "official" ], output.fetch("source_ids")
  end

  def test_evidence_updates_comparable_unobserved_races_by_shared_covariance
    races = [ race("NC-S", sigma: 3), race("NC-01", chamber: "house", sigma: 3), race("AZ-01", state: "AZ", chamber: "house", sigma: 3) ]
    result = run_model(races, [ observation("NC-S", margin: 10, sigma: 2) ])
    outputs = result.fetch("races").to_h { |item| [ item.fetch("race_key"), item ] }

    assert_in_delta 10.0 * 14 / 18, outputs.fetch("NC-S").fetch("mean_margin"), 1e-12
    assert_in_delta 10.0 * 5 / 18, outputs.fetch("NC-01").fetch("mean_margin"), 1e-12
    assert_in_delta 10.0 / 18, outputs.fetch("AZ-01").fetch("mean_margin"), 1e-12
    assert_equal "shared_update", outputs.fetch("NC-01").fetch("status")
    refute outputs.fetch("NC-01").fetch("direct_observation")
    assert_nil outputs.fetch("NC-01").fetch("counted_fraction")
  end

  def test_optional_division_effect_propagates_to_same_division
    races = [ race("NC-S"), race("GA-S", state: "GA"), race("AZ-S", state: "AZ") ]
    result = run_model(races, [ observation("NC-S", margin: 5) ], sigma_regional: 2)
    outputs = result.fetch("races").to_h { |item| [ item.fetch("race_key"), item ] }
    assert_operator outputs.fetch("GA-S").fetch("mean_margin"), :>, outputs.fetch("AZ-S").fetch("mean_margin")
  end

  def test_shared_reporting_bias_does_not_become_final_voter_swing
    races = [ race("NC-S", sigma: 3), race("NC-01", chamber: "house", sigma: 3) ]
    result = run_model(races, [ observation("NC-S", margin: 10, sigma: 2) ], sigma_reporting_bias: 4)
    outputs = result.fetch("races").to_h { |item| [ item.fetch("race_key"), item ] }
    # Measurement variance = 14 final-margin variance + 16 reporting bias +
    # 4 independent noise. Final margins exclude the reporting-bias factor.
    assert_in_delta 10.0 * 14 / 34, outputs.fetch("NC-S").fetch("mean_margin"), 1e-12
    assert_in_delta 10.0 * 5 / 34, outputs.fetch("NC-01").fetch("mean_margin"), 1e-12
    assert_in_delta 10.0 * 16 / 34, result.dig("diagnostics", "shared_effects", "reporting_bias:NC"), 1e-12
  end

  def test_repeating_same_state_evidence_preserves_reporting_bias_uncertainty
    races = 21.times.map { |i| race("NC-#{i + 1}", chamber: "house", sigma: 3) }
    observations = races.first(20).map { |r| observation(r.fetch("race_key"), margin: 10, sigma: 2) }
    result = run_model(races, observations, sigma_reporting_bias: 4, n_sims: 100)
    held_out = result.fetch("races").find { |race| race.fetch("race_key") == "NC-21" }
    # Twenty observations reduce independent noise to 13/20, but the 16
    # points² of shared reporting error cannot be averaged away.
    assert_in_delta 10.0 * 5 / (5 + 16 + 13.0 / 20), held_out.fetch("mean_margin"), 1e-10
    assert_operator held_out.fetch("mean_margin"), :<, 3
  end

  def test_conflicting_observations_match_joint_conditioning
    races = [ race("NC-S", sigma: 2), race("AZ-S", state: "AZ", sigma: 2) ]
    observations = [ observation("NC-S", margin: 8, sigma: 2), observation("AZ-S", margin: -8, sigma: 2) ]
    # With zero state variance the measurement covariance is [[9,1],[1,9]].
    # Applying its inverse to [8,-8] yields [1,-1]; each latent race mean is
    # therefore +4/-4 and the national posterior mean is exactly zero.
    result = run_model(races, observations, sigma_state: 0)
    outputs = result.fetch("races").to_h { |item| [ item.fetch("race_key"), item ] }
    assert_in_delta 4, outputs.fetch("NC-S").fetch("mean_margin"), 1e-12
    assert_in_delta(-4, outputs.fetch("AZ-S").fetch("mean_margin"), 1e-12)
    assert_in_delta 0, result.dig("diagnostics", "shared_effects", "national"), 1e-12
  end

  def test_simulated_chamber_distribution_preserves_shared_error
    races = [ race("NC-01", chamber: "house", sigma: 1), race("AZ-01", state: "AZ", chamber: "house", sigma: 1) ]
    result = run_model(races, [], n_sims: 30_000, sigma_state: 0, sigma_national: 3, house_majority: 2)
    house = result.dig("chambers", "house")
    assert_operator house.fetch("p_dem_control"), :>, 0.40
    assert_operator house.fetch("seat_histogram").fetch("1").to_f / 30_000, :<, 0.20
    assert_equal 30_000, house.fetch("seat_histogram").values.sum
  end

  def test_independent_wins_and_caucus_control_are_different_questions
    independent = { "party" => "independent", "caucus" => "uncommitted", "name" => "Independent" }
    contest = race("NE-S", state: "NE").merge("side_a" => independent, "certain" => independent)
    result = run_model([ contest ], [], senate_dem_holdover: 50, senate_rep_holdover: 49)
    assert_equal 1.0, result.fetch("races").first.fetch("p_other_win")
    assert_equal 0.0, result.dig("chambers", "senate", "p_dem_control")
    assert_equal 0.0, result.dig("chambers", "senate", "p_rep_control")
    assert_equal 1.0, result.dig("chambers", "senate", "p_unresolved_control")

    independent["caucus"] = "dem"
    result = run_model([ contest ], [], senate_dem_holdover: 50, senate_rep_holdover: 49)
    assert_equal 1.0, result.fetch("races").first.fetch("p_other_win")
    assert_equal 1.0, result.dig("chambers", "senate", "p_dem_control")
  end

  def test_full_coverage_is_not_a_call_and_measurement_floor_applies
    result = run_model([ race("NC-S") ], [ observation("NC-S", margin: 1, sigma: 0, fraction: 1) ], n_sims: 10_000)
    output = result.fetch("races").first
    assert_equal 2.0, output.fetch("measurement_sigma")
    assert_operator output.fetch("p_dem_win"), :<, 0.99
    assert_operator output.fetch("p_rep_win"), :>, 0.01
    assert_equal "returns_updated", output.fetch("status")
  end

  def test_counted_fraction_does_not_double_apply_measurement_confidence
    races = [ race("NC-S") ]
    low = run_model(races, [ observation("NC-S", fraction: 0.1) ])
    high = run_model(races, [ observation("NC-S", fraction: 0.9) ])
    assert_equal low.fetch("chambers"), high.fetch("chambers")
    assert_equal low.fetch("races").first.fetch("p_dem_win"), high.fetch("races").first.fetch("p_dem_win")
  end

  def test_reproducible_and_invariant_to_input_order_without_mutating_inputs
    races = [ race("NC-S"), race("AZ-S", state: "AZ") ]
    observations = [ observation("NC-S", margin: 4), observation("AZ-S", margin: -2) ]
    saved = Marshal.dump([ races, observations ])
    first = run_model(races, observations)
    assert_equal first, run_model(races.reverse, observations.reverse)
    assert_equal saved, Marshal.dump([ races, observations ])
  end

  def test_zero_shared_variance_is_supported
    result = run_model([ race("NC-S", mu: 5, sigma: 0) ], [], sigma_national: 0, sigma_state: 0)
    assert_equal 1.0, result.fetch("races").first.fetch("p_dem_win")
    assert_equal 0, result.dig("diagnostics", "shared_factor_count")
  end

  def test_rejects_duplicate_unknown_zero_coverage_and_invalid_measurements
    races = [ race("NC-S") ]
    [
      [ observation("NC-S"), observation("NC-S") ],
      [ observation("GA-S") ],
      [ observation("NC-S", fraction: 0) ],
      [ observation("NC-S", fraction: 1.1) ],
      [ observation("NC-S", sigma: -1) ],
      [ observation("NC-S", margin: Float::NAN) ],
      [ observation("NC-S", margin: Float::INFINITY) ]
    ].each { |observations| assert_raises(ArgumentError) { run_model(races, observations) } }
    assert_raises(ArgumentError) { run_model(races + races, []) }
    assert_raises(ArgumentError) { run_model(races, [], sigma_national: -1) }
    assert_raises(ArgumentError) { run_model(races, [], n_sims: 0) }
  end

  private
    def race(key, state: "NC", chamber: "senate", mu: 0, sigma: 3)
      { "race_key" => key, "state" => state, "chamber" => chamber, "mu" => mu, "sigma" => sigma,
        "side_a" => { "party" => "dem", "caucus" => "dem", "name" => "Democrat" },
        "side_b" => { "party" => "rep", "caucus" => "rep", "name" => "Republican" } }
    end

    def observation(key, margin: 4, sigma: 2, fraction: 0.5)
      { "race_key" => key, "observed_margin" => margin, "sigma" => sigma,
        "counted_fraction" => fraction, "source_ids" => [ "official" ] }
    end

    def run_model(races, observations, n_sims: 500, **params)
      prior = { "races" => races, "sigma_national" => 1, "sigma_state" => 2,
                "observation_sigma_inflation" => 1.0, "sigma_reporting_bias" => 0 }.merge(params.transform_keys(&:to_s))
      ElectionNight::Nowcast.new(prior: prior, observations: observations, seed: 5352026, n_sims: n_sims).call
    end
end
