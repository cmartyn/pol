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

  def test_primary_aggregate_precedes_healthy_fallback_county_detail
    primary = source("civic", [ aggregate ], priority: 0)
    official = source("official", [ county("A"), county("B") ], expected_counties: 2, priority: 10, source_role: "fallback")
    resolver = ElectionNight::RawResults.new(sources: [ official, primary ])
    assert_equal [ "civic" ], resolver.for_race(race)["raw_source_ids"]
    refute resolver.for_race(race)["raw_source_fallback"]
    primary["status"] = "error"
    fallback = ElectionNight::RawResults.new(sources: [ official, primary ]).for_race(race)
    assert_equal [ "official" ], fallback["raw_source_ids"]
    assert fallback["raw_source_fallback"]
  end

  def test_newer_export_or_fetch_time_does_not_establish_a_newer_count_batch
    [ 0, 250 ].each do |votes|
      primary = source("civic", [ aggregate(votes, votes) ], priority: 0, source_role: "primary",
        published_at: "2026-11-03T18:00:00Z", fetched_at: "2026-11-04T01:00:00Z")
      [ nil, "2026-11-04T01:00:00Z", "2026-11-04T01:00:00" ].each do |export_timestamp|
        official = source("official", [ county("A"), county("B") ], priority: 10, source_role: "fallback",
          source_kind: "official", expected_counties: 2, published_at: export_timestamp,
          fetched_at: "2026-11-04T02:00:00Z")
        result = ElectionNight::RawResults.new(sources: [ primary, official ]).for_race(race)
        assert_equal [ "civic" ], result["raw_source_ids"]
        refute result["raw_source_fallback"]
        assert_equal votes * 2, result["observed_votes"]
      end
    end
  end

  def test_independent_historical_manifest_can_validate_a_zero_primary_county_scaffold
    primary = source("civic", [ county("A", 0, 0), county("B", 0, 0), aggregate(0, 0) ], priority: 0)
    resolver = ElectionNight::RawResults.new(sources: [ primary ])
    assert_equal "contest", resolver.for_race(race)["raw_coverage_level"]
    assert_equal "county", resolver.for_race(race, historical_counties: %w[A B])["raw_coverage_level"]
    assert_equal "contest", resolver.for_race(race, historical_counties: %w[A B C])["raw_coverage_level"]
  end

  def test_model_counties_come_from_one_complete_snapshot_without_filling_primary_gaps
    primary = source("civic", [ county("A", 60, 40) ], priority: 0)
    official = source("official", [ county("A", 30, 70), county("B", 50, 50) ], priority: 10)
    resolver = ElectionNight::RawResults.new(sources: [ official, primary ])
    matched = resolver.matched_counties("NC-S", expected_counties: %w[A B])
    assert_equal [ "official" ], matched.map { |row| row["source_id"] }.uniq
    assert_equal 80, matched.sum { |row| row["dem_votes"] }
    assert_nil resolver.matched_counties("NC-S", expected_counties: %w[A B C])
  end

  def alias_normalizer
    Object.new.tap do |normalizer|
      def normalizer.normalize(_state, unit)
        unit.merge("unit_key" => unit.fetch("unit_key").delete("."), "historical_county_match" => true)
      end
    end
  end

  def test_canonical_county_collision_withholds_entire_source_race_not_first_row_or_sum
    rows = [ county("A.", 40, 10), county("A", 20, 30), county("B", 60, 40) ]
    primary = source("civic", rows, expected_counties: 2)
    primary["results"]["aggregate_units"] = [ aggregate(120, 80) ]
    resolver = ElectionNight::RawResults.new(sources: [ primary ], county_identity: alias_normalizer)

    assert_empty resolver.county_units
    assert_empty resolver.state_manifests
    assert_nil resolver.matched_counties("NC-S", expected_counties: %w[A B])
    result = resolver.for_race(race, historical_counties: %w[A B])
    assert_equal "contest", result["raw_coverage_level"]
    assert_equal 200, result["observed_votes"]
    assert_equal [ "A.", "A" ], resolver.county_rejections.first["source_unit_keys"]
    assert_equal [ "A.", "A", "B" ], rows.map { |row| row["unit_key"] }, "normalization must not mutate raw source records"
  end

  def test_collision_uses_one_clean_fallback_for_model_and_preserves_other_races
    primary = source("civic", [ county("A."), county("A"), county("B"), county("C", 60, 40, "NC-01") ], priority: 0)
    fallback = source("official", [ county("A", 10, 20), county("B", 30, 40) ], priority: 10, expected_counties: 2)
    resolver = ElectionNight::RawResults.new(sources: [ primary, fallback ], county_identity: alias_normalizer)
    model_rows = resolver.matched_counties("NC-S", expected_counties: %w[A B])
    assert_equal [ "official" ], model_rows.map { |row| row["source_id"] }.uniq
    assert_equal 100, model_rows.sum { |row| row["total_votes"] }
    assert_equal [ "official" ], resolver.for_race(race)["raw_source_ids"]
    assert_equal [ "civic" ], resolver.matched_counties("NC-01", expected_counties: [ "C" ]).map { |row| row["source_id"] }
    assert_equal [ "NC-S" ], resolver.county_rejections.map { |rejection| rejection["race_key"] }.uniq
  end

  def test_exact_duplicate_county_rows_are_also_ambiguous_without_deduplication_proof
    row = county("A")
    resolver = ElectionNight::RawResults.new(sources: [ source("duplicate", [ row, row.dup ], expected_counties: 1) ])
    refute resolver.for_race(race)["has_raw_source"]
    assert_nil resolver.matched_counties("NC-S", expected_counties: [ "A" ])
    assert_empty resolver.state_manifests
    assert_equal 1, resolver.county_rejections.size
  end

  def test_at_large_aliases_cannot_hide_duplicate_county_geography
    rows = [ county("A", 60, 40, "AK-01"), county("A", 30, 20, "AK-AL") ]
    resolver = ElectionNight::RawResults.new(sources: [ source("duplicate", rows, state: "AK") ])
    assert_empty resolver.county_units
    assert_nil resolver.matched_counties("AK-AL", expected_counties: [ "A" ])
    assert_equal "AK-AL", resolver.county_rejections.first["race_key"]
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
