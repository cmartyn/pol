require "minitest/autorun"

module ElectionNight
end

require_relative "../../../app/lib/election_night/raw_results"

class ElectionNightRawResultsTest < Minitest::Test
  def race
    { "race_key" => "NC-S", "state" => "NC", "chamber" => "senate" }
  end

  def county(name, dem = 60, rep = 40, key = "NC-S")
    { "race_key" => key, "unit_key" => name, "dem_votes" => dem, "rep_votes" => rep,
      "other_votes" => 0, "total_votes" => dem + rep }
  end

  def source(id, rows, **extras)
    { "id" => id, "state" => "NC", "usable" => true, "status" => "ok", "results" => { "units" => rows } }.merge(extras.transform_keys(&:to_s))
  end

  def aggregate(dem = 150, rep = 150)
    county("STATEWIDE", dem, rep).merge("aggregate_only" => true, "geography_level" => "contest")
  end

  def test_complete_county_source_wins_over_aggregate_and_mirrors_without_double_counting
    official = source("official", [ county("A"), county("B") ], expected_counties: 2)
    mirror = source("mirror", official["results"]["units"])
    resolver = ElectionNight::RawResults.new(sources: [ official, mirror, source("aggregate", [ aggregate ]) ])
    result = resolver.for_race(race)
    assert_equal 200, result["observed_votes"]
    assert_equal [ "official" ], result["raw_source_ids"]
    assert_equal "county", result["raw_coverage_level"]
    assert_equal 2, resolver.county_units.size
  end

  def test_aggregate_beats_partial_counties_and_never_enters_geographic_manifest
    partial = source("county", [ county("A") ])
    totals = source("aggregate", [ aggregate ], expected_counties: 1)
    resolver = ElectionNight::RawResults.new(sources: [ partial, totals ])
    result = resolver.for_race(race)
    assert_equal 300, result["observed_votes"]
    assert_equal "contest", result["raw_coverage_level"]
    assert_equal [ "aggregate" ], result["raw_source_ids"]
    assert_empty resolver.state_manifests
    assert_equal 1, resolver.county_units.size
  end

  def test_partial_counties_are_deduplicated_and_labeled_partial
    resolver = ElectionNight::RawResults.new(sources: [ source("first", [ county("A") ]), source("mirror", [ county("A", 80, 40), county("B") ]) ])
    result = resolver.for_race(race)
    assert_equal 200, result["observed_votes"]
    assert_equal "partial", result["raw_coverage_level"]
    assert_equal [ "first", "mirror" ], result["raw_source_ids"]
  end

  def test_failed_source_is_ignored_but_explicitly_retained_last_good_is_usable
    failed = source("failed", [ aggregate(999, 999) ], usable: false, status: "error")
    retained = source("retained", [ aggregate ], status: "error", published_at: "2026-11-04T01:00:00Z")
    result = ElectionNight::RawResults.new(sources: [ failed, retained ]).for_race(race)
    assert_equal 300, result["observed_votes"]
    assert_equal [ "retained" ], result["raw_source_ids"]
    assert result["raw_source_stale"]
    assert_equal "2026-11-04T01:00:00Z", result["raw_source_published_at"]
  end

  def test_healthy_aggregate_beats_retained_counties_even_when_official_is_first
    %w[error stale].each do |status|
      official = source("official", [ county("A", 0, 0) ], expected_counties: 1, status: status)
      fresh = source("fresh", [ aggregate ])
      result = ElectionNight::RawResults.new(sources: [ official, fresh ]).for_race(race)
      assert_equal 300, result["observed_votes"]
      assert_equal "contest", result["raw_coverage_level"]
      assert_equal [ "fresh" ], result["raw_source_ids"]
      refute result["raw_source_stale"]
    end
  end

  def test_healthy_duplicate_counties_supply_model_rows_before_retained_rows
    old = source("old", [ county("A", 0, 0), county("B", 0, 0) ], status: "error", expected_counties: 2)
    fresh = source("fresh", [ county("A"), county("B") ], expected_counties: 2)
    resolver = ElectionNight::RawResults.new(sources: [ old, fresh ])
    assert_equal [ "fresh" ], resolver.county_units.values.map { |unit| unit["source_id"] }.uniq
    assert_equal 200, resolver.county_units.values.sum { |unit| unit["total_votes"] }
    assert_equal [ "fresh" ], resolver.for_race(race)["raw_source_ids"]
  end

  def test_retained_whole_race_total_beats_healthy_partial_county_total
    fresh = source("partial", [ county("A") ])
    old = source("retained", [ aggregate ], status: "stale")
    result = ElectionNight::RawResults.new(sources: [ fresh, old ]).for_race(race)
    assert_equal 300, result["observed_votes"]
    assert_equal "contest", result["raw_coverage_level"]
    assert_equal [ "retained" ], result["raw_source_ids"]
    assert result["raw_source_stale"]
  end

  def test_zero_scaffold_is_available_but_absent_source_is_not_zero_reporting
    available = ElectionNight::RawResults.new(sources: [ source("zero", [ aggregate(0, 0) ]) ]).for_race(race)
    missing = ElectionNight::RawResults.new(sources: []).for_race(race)
    assert_equal 0, available["observed_votes"]
    assert available["has_raw_source"]
    refute missing["has_raw_source"]
    assert_equal "none", missing["raw_coverage_level"]
  end

  def test_reconciled_county_details_can_display_as_full_county_snapshot_without_model_manifest
    provider = source("civic", [ county("A"), county("B") ])
    provider["results"].merge!("aggregate_units" => [ aggregate(120, 80) ], "county_totals_match_aggregate" => true)
    resolver = ElectionNight::RawResults.new(sources: [ provider ])
    result = resolver.for_race(race)
    assert_equal 200, result["observed_votes"]
    assert_equal "county", result["raw_coverage_level"]
    assert_empty resolver.state_manifests
    provider["results"]["units"].pop
    result = ElectionNight::RawResults.new(sources: [ provider ]).for_race(race)
    assert_equal 200, result["observed_votes"]
    assert_equal "contest", result["raw_coverage_level"]
  end

  def test_zero_county_reconciliation_retains_aggregate_without_claiming_complete_geography
    provider = source("civic", [ county("A", 0, 0), county("B", 0, 0) ])
    provider["results"].merge!("aggregate_units" => [ aggregate(0, 0) ], "county_totals_match_aggregate" => true)
    [ 2, 1 ].each do |size|
      provider["results"]["units"] = provider["results"]["units"].first(size)
      resolver = ElectionNight::RawResults.new(sources: [ provider ])
      result = resolver.for_race(race)
      assert_equal "contest", result["raw_coverage_level"]
      assert_equal 0, result["observed_votes"]
      assert result["has_raw_source"]
      assert_equal size, resolver.county_units.size
      assert_empty resolver.state_manifests
    end
  end

  def test_independently_validated_county_scaffold_can_still_report_zero
    official = source("official", [ county("A", 0, 0), county("B", 0, 0) ], expected_counties: 2)
    result = ElectionNight::RawResults.new(sources: [ official ]).for_race(race)
    assert_equal "county", result["raw_coverage_level"]
    assert_equal 0, result["observed_votes"]
  end

  def test_frozen_at_large_prior_aliases_find_canonical_results_without_mutating_prior
    %w[AK DE ND SD VT WY].each do |state|
      provider = source("atlarge", [ aggregate.merge("race_key" => "#{state}-AL") ], state: state)
      resolver = ElectionNight::RawResults.new(sources: [ provider ])
      %w[00 01 AL].each do |district|
        prior = { "race_key" => "#{state}-#{district}", "state" => state, "chamber" => "house" }.freeze
        result = resolver.for_race(prior)
        assert_equal 300, result["observed_votes"]
        assert_equal "contest", result["raw_coverage_level"]
        assert_equal "#{state}-#{district}", prior["race_key"]
      end
    end
    old_format = source("alias", [ county("A", 60, 40, "AK-01") ], state: "AK")
    resolver = ElectionNight::RawResults.new(sources: [ old_format ])
    assert_equal [ [ "AK-AL", "A" ] ], resolver.county_units.keys
    assert_equal "AK-AL", resolver.county_units.values.first["race_key"]
    assert_equal "CA-01", ElectionNight::RawResults.canonical_race_key("CA-01")
  end

  def test_publisher_call_and_percent_fields_do_not_affect_selection_or_vote_totals
    unit = aggregate.merge("winner" => "D", "p_dem_win" => 1.0, "percentCounted" => 100, "called" => true)
    result = ElectionNight::RawResults.new(sources: [ source("publisher", [ unit ]) ]).for_race(race)
    assert_equal 300, result["observed_votes"]
    assert_equal 150, result["raw_dem_votes"]
    refute result.key?("p_dem_win")
    refute result.key?("called")
  end

  def test_known_incomplete_house_scaffold_falls_back_to_aggregate
    house = { "race_key" => "NC-01", "state" => "NC", "chamber" => "house" }
    official = source("official", [ county("A", 60, 40, "NC-01"), county("B", 60, 40, "NC-02") ], expected_counties: 2)
    full = source("totals", [ aggregate.merge("race_key" => "NC-01") ])
    result = ElectionNight::RawResults.new(sources: [ official, full ]).for_race(house, historical_counties: %w[A B])
    assert_equal "contest", result["raw_coverage_level"]
    assert_equal 300, result["observed_votes"]
  end

  def test_unknown_geography_and_invalid_vote_totals_do_not_create_coverage
    units = [ county("PRECINCT 1").merge("geography_level" => "precinct"), aggregate.merge("total_votes" => 999) ]
    result = ElectionNight::RawResults.new(sources: [ source("bad", units) ]).for_race(race)
    refute result["has_raw_source"]
  end

  def test_race_timestamp_overrides_newer_national_export_timestamp
    rows = [ aggregate.merge("published_at" => "2026-11-04T01:00:00Z") ]
    national = source("national", rows, published_at: "2026-11-04T02:00:00Z")
    result = ElectionNight::RawResults.new(sources: [ national ]).for_race(race)
    assert_equal "2026-11-04T01:00:00Z", result["raw_source_published_at"]
  end

  def test_mixed_counties_use_oldest_row_or_fallback_source_timestamp
    rows = [ county("A").merge("published_at" => "2026-11-04T01:00:00Z"), county("B") ]
    official = source("official", rows, expected_counties: 2, published_at: "2026-11-04T02:00:00Z")
    result = ElectionNight::RawResults.new(sources: [ official ]).for_race(race)
    assert_equal "2026-11-04T01:00:00Z", result["raw_source_published_at"]
  end
end
