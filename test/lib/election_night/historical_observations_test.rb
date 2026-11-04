require "test_helper"

class ElectionNight::HistoricalObservationsTest < ActiveSupport::TestCase
  def race(key = "NC-S", chamber = "senate", compatible: false)
    { "race_key" => key, "state" => "NC", "chamber" => chamber, "mu" => 0,
      "historical_house_compatible" => compatible,
      "side_a" => { "party" => "dem" }, "side_b" => { "party" => "rep" } }
  end

  def unit(key, county, dem, rep, fips: nil)
    { "race_key" => key, "state" => "NC", "unit_key" => county,
      "county_fips" => fips || { "URBAN" => "37001", "RURAL" => "37003" }[county],
      "dem_votes" => dem, "rep_votes" => rep, "other_votes" => 0, "total_votes" => dem + rep }
  end

  def history(house: false)
    rows = [ unit("NC-P", "URBAN", 80_000, 20_000), unit("NC-P", "RURAL", 20_000, 80_000) ]
    { "units" => rows, "house_units" => house ? rows.map { |row| row.merge("race_key" => "NC-01") } : [],
      "state_manifests" => { "NC" => %w[RURAL URBAN] }, "turnout_2022" => [], "turnout_state_manifests" => {},
      "house_totals_current_lines" => [ unit("NC-01", "CONTEST", 100_000, 100_000).merge("aggregate_only" => true) ] }
  end

  def source(rows, aggregate_only: false)
    key = rows.first.fetch("race_key")
    aggregate = unit(key, "CONTEST", rows.sum { |row| row["dem_votes"] }, rows.sum { |row| row["rep_votes"] }).merge("aggregate_only" => true)
    { "id" => "civic", "state" => "NC", "status" => "ok", "usable" => true,
      "results" => { "units" => aggregate_only ? [] : rows, "aggregate_units" => [ aggregate ], "county_totals_match_aggregate" => !aggregate_only } }
  end

  def builder(rows, history: self.history, race: self.race, aggregate_only: false)
    ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ source(rows, aggregate_only: aggregate_only) ], historical: history)
  end

  def zeros(key = "NC-S")
    %w[URBAN RURAL].map { |county| unit(key, county, 0, 0) }
  end

  test "an independent historical manifest makes a Civic zero scaffold a baseline but not evidence" do
    estimate = builder(zeros)
    assert_empty estimate.call
    coverage = estimate.coverage.fetch("NC-S")
    assert coverage["has_baseline"]
    assert_equal "county", coverage["raw_coverage_level"]
    assert_equal "county", coverage.dig("outstanding_votes", "geography_scope")
    assert_equal 150_000, coverage.dig("outstanding_votes", "remaining_votes")
    assert_equal 0, coverage.dig("outstanding_votes", "counted_fraction")
    refute coverage.fetch("outstanding_votes").key?("measurement")
  end

  test "only a complete independently verified Senate midterm scaffold supplies turnout anchors" do
    baseline = history
    baseline["turnout_2022"] = [ unit("NC-S", "URBAN", 36_000, 24_000), unit("NC-S", "RURAL", 24_000, 36_000) ]
    baseline["turnout_state_manifests"] = { "NC" => %w[RURAL URBAN] }
    estimate = builder(zeros, history: baseline)
    assert_empty estimate.call
    assert_equal 2, estimate.coverage.dig("NC-S", "outstanding_votes", "midterm_anchored_units")
    assert_equal 120_000, estimate.coverage.dig("NC-S", "outstanding_votes", "projected_total_votes")

    baseline["turnout_2022"].pop
    baseline["turnout_state_manifests"] = { "NC" => [ "URBAN" ] }
    estimate = builder(zeros, history: baseline)
    assert_empty estimate.call
    assert_equal 0, estimate.coverage.dig("NC-S", "outstanding_votes", "midterm_anchored_units")
    assert_equal 150_000, estimate.coverage.dig("NC-S", "outstanding_votes", "projected_total_votes")
  end

  test "a stale midterm manifest cannot hide a missing turnout row" do
    baseline = history
    baseline["turnout_2022"] = [ unit("NC-S", "URBAN", 36_000, 24_000) ]
    baseline["turnout_state_manifests"] = { "NC" => %w[RURAL URBAN] }
    estimate = builder(zeros, history: baseline)
    assert_empty estimate.call
    assert_equal 0, estimate.coverage.dig("NC-S", "outstanding_votes", "midterm_anchored_units")
  end

  test "House turnout never borrows 2022 district boundaries implicitly" do
    baseline = history(house: true)
    baseline["turnout_2022"] = [ unit("NC-01", "URBAN", 6000, 4000), unit("NC-01", "RURAL", 4000, 6000) ]
    baseline["turnout_state_manifests"] = { "NC" => %w[RURAL URBAN] }
    estimate = builder(zeros("NC-01"), history: baseline, race: race("NC-01", "house", compatible: true))
    assert_empty estimate.call
    assert_equal 0, estimate.coverage.dig("NC-01", "outstanding_votes", "midterm_anchored_units")
    assert_equal 2, estimate.coverage.dig("NC-01", "outstanding_votes", "fallback_units")
    assert_equal 150_000, estimate.coverage.dig("NC-01", "outstanding_votes", "projected_total_votes")
  end

  test "a redrawn House race can have an aggregate remaining diagnostic without direct conditioning" do
    rows = [ unit("NC-01", "CONTEST", 60_000, 40_000) ]
    estimate = builder(rows, history: history(house: true), race: race("NC-01", "house"), aggregate_only: true)
    assert_empty estimate.call
    coverage = estimate.coverage.fetch("NC-01")
    assert_equal "contest", coverage.dig("outstanding_votes", "geography_scope")
    assert_equal 50_000, coverage.dig("outstanding_votes", "remaining_votes")
    refute coverage["has_baseline"]
    refute coverage.fetch("outstanding_votes").key?("measurement")
    refute coverage.fetch("outstanding_votes").key?("units")
  end

  test "canonical FIPS joins work while missing extra and unknown county rows refuse direct inference" do
    complete = [ unit("NC-S", "Urban report", 40_000, 10_000, fips: "37001"), unit("NC-S", "Rural report", 10_000, 40_000, fips: "37003") ]
    assert_equal 1, builder(complete).call.size
    [ complete.first(1), complete + [ unit("NC-S", "EXTRA", 1000, 1000, fips: "37005") ],
      [ complete.first.merge("county_fips" => "99999"), complete.last ] ].each do |rows|
      estimate = builder(rows)
      assert_empty estimate.call
      assert_match(/scaffold differs/, estimate.coverage.dig("NC-S", "reason"))
    end
  end

  test "a publisher county count cannot replace an independent named state manifest" do
    rows = [ unit("NC-S", "URBAN", 40_000, 10_000), unit("NC-S", "EXTRA", 10_000, 40_000, fips: "37005") ]
    publisher = source(rows)
    publisher["expected_counties"] = 2
    publisher["baseline"] = { "units" => [ unit("NC-P", "EXTRA", 20_000, 80_000, fips: "37005") ] }
    estimate = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ publisher ], historical: history)
    assert_empty estimate.call
    assert_match(/scaffold differs/, estimate.coverage.dig("NC-S", "reason"))
  end

  test "a highly partisan county remains usable when the full historical House race was contested" do
    baseline = history(house: true)
    baseline["house_units"] = [ unit("NC-01", "URBAN", 99_000, 1000), unit("NC-01", "RURAL", 1000, 99_000) ]
    rows = [ unit("NC-01", "URBAN", 49_500, 500), unit("NC-01", "RURAL", 500, 49_500) ]
    estimate = builder(rows, history: baseline, race: race("NC-01", "house", compatible: true))
    result = estimate.call
    assert_equal 1, result.size
    assert_in_delta 0, result.first["observed_margin"], 1e-9
    assert estimate.coverage.dig("NC-01", "has_baseline")
  end

  test "the lower counted-fraction bound withholds evidence despite a point fraction over fifteen percent" do
    rows = [ unit("NC-S", "URBAN", 10_400, 2600), unit("NC-S", "RURAL", 2600, 10_400) ]
    estimate = builder(rows)
    assert_empty estimate.call
    outstanding = estimate.coverage.dig("NC-S", "outstanding_votes")
    assert_operator outstanding.fetch("counted_fraction"), :>, 0.15
    assert_operator outstanding.fetch("counted_fraction_low"), :<, 0.15
    assert_equal 1, outstanding.fetch("represented_fraction")
    assert estimate.coverage.dig("NC-S", "has_baseline")
  end

  test "displayed remaining totals follow selected raw counts instead of a stale county snapshot" do
    primary = source([ unit("NC-S", "CONTEST", 60_000, 40_000) ], aggregate_only: true).merge("id" => "primary")
    stale = source([ unit("NC-S", "URBAN", 800, 200), unit("NC-S", "RURAL", 200, 800) ]).merge("id" => "old_official", "status" => "stale")
    estimate = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ stale, primary ], historical: history)
    assert_empty estimate.call
    coverage = estimate.coverage.fetch("NC-S")
    assert_equal [ "primary" ], coverage.fetch("raw_source_ids")
    assert_equal 100_000, coverage.fetch("observed_votes")
    assert_equal coverage.fetch("observed_votes"), coverage.dig("outstanding_votes", "counted_votes")
    assert_equal 50_000, coverage.dig("outstanding_votes", "remaining_votes")
    assert_equal "contest", coverage.dig("outstanding_votes", "geography_scope")
  end

  test "strong fallback county evidence keeps its source IDs while public estimates follow the primary aggregate" do
    primary = source([ unit("NC-S", "CONTEST", 60_000, 40_000) ], aggregate_only: true).merge("id" => "primary", "priority" => 0)
    fallback = source([ unit("NC-S", "URBAN", 35_000, 5000), unit("NC-S", "RURAL", 5000, 35_000) ])
      .merge("id" => "county_fallback", "priority" => 10, "source_role" => "fallback")
    estimate = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ fallback, primary ], historical: history)
    result = estimate.call
    assert_equal 1, result.size
    assert_equal [ "county_fallback" ], result.first.fetch("source_ids")
    coverage = estimate.coverage.fetch("NC-S")
    assert_equal [ "primary" ], coverage.fetch("raw_source_ids")
    assert_equal [ "county_fallback" ], coverage.fetch("model_source_ids")
    assert_equal 100_000, coverage.dig("outstanding_votes", "counted_votes")
    assert_equal 50_000, coverage.dig("outstanding_votes", "remaining_votes")
    assert_equal "contest", coverage.dig("outstanding_votes", "geography_scope")
  end

  test "a mismatched county estimate stays private when the selected aggregate has no compatible turnout history" do
    primary = source([ unit("NC-01", "CONTEST", 60_000, 40_000) ], aggregate_only: true).merge("id" => "primary", "priority" => 0)
    fallback = source([ unit("NC-01", "URBAN", 35_000, 5000), unit("NC-01", "RURAL", 5000, 35_000) ])
      .merge("id" => "county_fallback", "priority" => 10)
    baseline = history(house: true).merge("house_totals_current_lines" => [])
    estimate = ElectionNight::Observations.new(prior: { "races" => [ race("NC-01", "house", compatible: true) ] },
      sources: [ primary, fallback ], historical: baseline)
    result = estimate.call
    assert_equal 1, result.size
    assert_equal [ "county_fallback" ], result.first.fetch("source_ids")
    assert_equal 100_000, estimate.coverage.dig("NC-01", "observed_votes")
    assert_nil estimate.coverage.dig("NC-01", "outstanding_votes")
  end
end
