require "test_helper"

class ElectionNight::ObservationsTest < ActiveSupport::TestCase
  def race(key = "NC-S", chamber = "senate")
    { "race_key" => key, "state" => "NC", "chamber" => chamber, "mu" => 0,
      "side_a" => { "party" => "dem" }, "side_b" => { "party" => "rep" } }
  end

  def unit(key, county, dem, rep)
    { "race_key" => key, "unit_key" => county, "dem_votes" => dem, "rep_votes" => rep,
      "other_votes" => 0, "total_votes" => dem + rep }
  end

  def source(rows)
    # Other contests keep the statewide scaffold complete even when the race
    # under test omits a county. The observation builder must detect that gap.
    missing = %w[URBAN RURAL] - rows.map { |row| row.fetch("unit_key") }.uniq
    rows = rows + missing.map { |county| unit("NC-99", county, 0, 0) }
    { "id" => "nc", "state" => "NC", "usable" => true, "expected_counties" => 2,
      "results" => { "units" => rows }, "baseline" => { "units" => [
        unit("NC-P", "URBAN", 80_000, 20_000), unit("NC-P", "RURAL", 20_000, 80_000)
      ] } }
  end

  test "early partisan geography alone does not invent a national swing" do
    rows = [ unit("NC-S", "URBAN", 40_000, 10_000), unit("NC-S", "RURAL", 0, 0) ]
    result = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ source(rows) ]).call
    assert_equal 1, result.size
    assert_in_delta 0, result.first.fetch("observed_margin"), 0.001
    assert_operator result.first.fetch("sigma"), :>, 8
  end

  test "zero scaffold and missing baseline never create evidence" do
    s = source([ unit("NC-S", "URBAN", 0, 0), unit("NC-S", "RURAL", 0, 0) ])
    assert_empty ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ s ]).call
    s["results"]["units"][0] = unit("NC-S", "URBAN", 40_000, 10_000)
    s.delete("baseline")
    assert_empty ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ s ]).call
  end

  test "a single county source cannot stand in for a whole senate electorate" do
    s = source([ unit("NC-S", "URBAN", 40_000, 10_000) ])
    s.delete("expected_counties")
    assert_empty ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ s ]).call
  end

  test "state and county mirrors do not double count votes" do
    s = source([ unit("NC-S", "URBAN", 40_000, 10_000), unit("NC-S", "RURAL", 10_000, 40_000) ])
    builder = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ s, s.merge("id" => "mirror") ])
    assert_equal 1, builder.call.size
    assert_equal 100_000, builder.coverage.fetch("NC-S").fetch("observed_votes")
  end

  test "split county House results are withheld from a county baseline" do
    s = source([ unit("NC-01", "URBAN", 40_000, 10_000), unit("NC-02", "URBAN", 10_000, 40_000) ])
    builder = ElectionNight::Observations.new(prior: { "races" => [ race("NC-01", "house") ] }, sources: [ s ])
    assert_empty builder.call
    assert_equal 50_000, builder.coverage.fetch("NC-01").fetch("observed_votes")
  end

  test "historical district portions enable split counties only on verified unchanged lines" do
    s = source([ unit("NC-01", "URBAN", 30_000, 20_000), unit("NC-02", "URBAN", 10_000, 40_000) ])
    s["baseline"]["house_units"] = [ unit("NC-01", "URBAN", 60_000, 40_000) ]
    unchanged = race("NC-01", "house").merge("historical_house_compatible" => true)
    result = ElectionNight::Observations.new(prior: { "races" => [ unchanged ] }, sources: [ s ]).call
    assert_equal 1, result.size
    assert_in_delta 20, result.first.fetch("observed_margin"), 0.001
    unchanged["historical_house_compatible"] = false
    assert_empty ElectionNight::Observations.new(prior: { "races" => [ unchanged ] }, sources: [ s ]).call
  end

  test "a complete state source cannot hide a missing senate county" do
    s = source([ unit("NC-S", "URBAN", 40_000, 10_000) ])
    builder = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ s ])
    assert_empty builder.call
    assert_match(/scaffold differs/, builder.coverage.fetch("NC-S").fetch("reason"))
    assert_equal 50_000, builder.coverage.fetch("NC-S").fetch("observed_votes")
  end

  test "a missing historical House component cannot masquerade as complete coverage" do
    s = source([ unit("NC-01", "URBAN", 40_000, 10_000) ])
    s["baseline"]["house_units"] = [ unit("NC-01", "URBAN", 80_000, 20_000), unit("NC-01", "RURAL", 20_000, 80_000) ]
    unchanged = race("NC-01", "house").merge("historical_house_compatible" => true)
    builder = ElectionNight::Observations.new(prior: { "races" => [ unchanged ] }, sources: [ s ])
    assert_empty builder.call
    assert_match(/scaffold differs/, builder.coverage.fetch("NC-01").fetch("reason"))
  end

  test "one present House contest does not prove a county is unsplit" do
    s = source([ unit("NC-01", "URBAN", 40_000, 10_000) ])
    builder = ElectionNight::Observations.new(prior: { "races" => [ race("NC-01", "house") ] }, sources: [ s ])
    assert_empty builder.call
    assert_match(/lacks a verified/, builder.coverage.fetch("NC-01").fetch("reason"))
  end

  test "aggregate mirror changes neither geography evidence nor displayed vote count" do
    official = source([ unit("NC-S", "URBAN", 40_000, 10_000), unit("NC-S", "RURAL", 10_000, 40_000) ])
    aggregate = { "id" => "totals", "state" => "NC", "usable" => true,
      "results" => { "units" => [ unit("NC-S", "STATEWIDE", 50_000, 50_000).merge("aggregate_only" => true) ] } }
    builder = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ official, aggregate ])
    result = builder.call
    assert_equal 1, result.size
    assert_in_delta 0, result.first["observed_margin"], 0.001
    assert_equal [ "nc" ], result.first["source_ids"]
    assert_equal 100_000, builder.coverage["NC-S"]["observed_votes"]
    assert_equal [ "nc" ], builder.coverage["NC-S"]["raw_source_ids"]
  end

  test "aggregate only returns are visible but cannot establish a state manifest or condition probabilities" do
    aggregate = { "id" => "totals", "state" => "NC", "usable" => true, "expected_counties" => 1,
      "results" => { "units" => [ unit("NC-S", "STATEWIDE", 60_000, 40_000).merge("aggregate_only" => true) ] } }
    builder = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ aggregate ])
    assert_empty builder.call
    coverage = builder.coverage["NC-S"]
    assert_equal 100_000, coverage["observed_votes"]
    assert_equal "contest", coverage["raw_coverage_level"]
    assert coverage["has_raw_source"]
    assert_match(/Contest totals available/, coverage["reason"])
  end

  test "partial county plus full aggregate displays full total while keeping direct update withheld" do
    partial = source([ unit("NC-S", "URBAN", 40_000, 10_000) ])
    partial.delete("expected_counties")
    aggregate = { "id" => "totals", "state" => "NC", "usable" => true,
      "results" => { "aggregate_units" => [ unit("NC-S", "STATEWIDE", 60_000, 40_000) ], "units" => [] } }
    builder = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ partial, aggregate ])
    assert_empty builder.call
    assert_equal 100_000, builder.coverage["NC-S"]["observed_votes"]
    assert_equal [ "totals" ], builder.coverage["NC-S"]["raw_source_ids"]
    assert_equal "contest", builder.coverage["NC-S"]["raw_coverage_level"]
  end

  test "publisher reconciled counties do not manufacture an independent model manifest" do
    civic = source([ unit("NC-S", "URBAN", 40_000, 10_000), unit("NC-S", "RURAL", 10_000, 40_000) ])
    civic.delete("expected_counties")
    civic["results"].merge!("aggregate_units" => [ unit("NC-S", "STATEWIDE", 50_000, 50_000) ], "county_totals_match_aggregate" => true)
    builder = ElectionNight::Observations.new(prior: { "races" => [ race ] }, sources: [ civic ])
    assert_empty builder.call
    assert_equal "county", builder.coverage["NC-S"]["raw_coverage_level"]
    assert_match(/complete race geography not established/, builder.coverage["NC-S"]["reason"])
  end
end
