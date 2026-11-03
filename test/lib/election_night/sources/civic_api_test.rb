require "minitest/autorun"

module ElectionNight
  module Sources
  end
end

%w[base civic_api].each do |name|
  require_relative "../../../../app/lib/election_night/sources/#{name}"
end

class ElectionNightCivicApiTest < Minitest::Test
  Error = ElectionNight::Sources::Base::InvalidData

  def fixture(name = "civic_al_house.json")
    JSON.parse(File.read(File.expand_path("../../../fixtures/files/election_night/northeast/#{name}", __dir__)))
  end

  def parser(state = "AL")
    ElectionNight::Sources::CivicApi.new(state: state)
  end

  def test_real_full_race_keeps_county_and_aggregate_separate
    result = parser.parse(fixture)
    assert_equal 16, result["units"].size
    assert_equal [ "AL-02" ], result["units"].map { |u| u["race_key"] }.uniq
    assert_equal [ "AL-02" ], result["aggregate_units"].map { |u| u["race_key"] }
    assert result["aggregate_units"][0]["aggregate_only"]
    assert result["county_totals_match_aggregate"]
    assert result["units"].none? { |u| u["complete"] }
    refute result.key?("percent_reporting")
  end

  def test_real_alaska_uses_one_geographic_level_and_all_candidates
    result = parser("AK").parse(fixture("civic_ak_senate.json"))
    assert_equal 30, result["units"].size, "do not add House districts, statewide summary or overseas rows"
    assert_equal "AK-S", result["aggregate_units"][0]["race_key"]
    assert result["county_totals_match_aggregate"]
  end

  def test_towns_and_precincts_are_not_added_to_counties
    data = fixture
    county = data["region_results"].values.first
    county["candidates"][0]["votes"] = 70
    county["candidates"][1]["votes"] = 30
    data["candidates"][0]["votes"] = 70
    data["candidates"][1]["votes"] = 30
    data["candidates"][0]["winner"] = true
    data["percent_reporting"] = 100
    data["region_results"]["town"] = county.merge("type" => "Town", "name" => "Example town")
    data["region_results"]["precinct"] = county.merge("type" => "Precinct", "name" => "Precinct 1")
    result = parser.parse(data)
    assert_equal 100, result["units"].sum { |u| u["total_votes"] }
    assert_equal 100, result["aggregate_units"][0]["total_votes"]
    refute result["aggregate_units"][0]["complete"], "calls and reporting percent do not establish completion"
  end

  def test_third_party_counts_are_preserved_and_candidate_sets_must_match
    data = fixture
    other = { "name" => "Independent Example", "party" => "Independent", "votes" => 0, "candidate_id" => 999 }
    data["candidates"] << other
    data["region_results"].each_value { |region| region["candidates"] << other.dup }
    data["region_results"].values.first["candidates"].last["votes"] = 7
    data["candidates"].last["votes"] = 7
    result = parser.parse(data)
    assert_equal 7, result["units"].sum { |u| u["other_votes"] }
    assert_equal 7, result["aggregate_units"][0]["other_votes"]
    data["region_results"].values.last["candidates"].pop
    result = parser.parse(data)
    assert_empty result["units"]
    assert_equal 7, result["aggregate_units"][0]["other_votes"]
    assert_match(/candidate lists differ/, result["county_detail_reason"])
  end

  def test_county_mismatch_retains_aggregate_without_using_partial_or_double_counted_units
    data = fixture
    data["candidates"][0]["votes"] = 100
    result = parser.parse(data)
    assert_empty result["units"]
    assert_equal 100, result["aggregate_units"][0]["dem_votes"]
    refute result["county_totals_match_aggregate"]
    assert_match(/do not reconcile/, result["county_detail_reason"])
    data["region_results"] = {}
    result = parser.parse(data)
    assert_empty result["units"]
    assert_equal 100, result["aggregate_units"][0]["dem_votes"]
    assert_match(/No county-level breakdown/, result["county_detail_reason"])
  end

  def test_rejects_test_elections_wrong_scope_state_date_and_national_or_state_races
    [ [ "country", "CA" ], [ "province", "US" ], [ "province", "GA" ],
      [ "test_data", true ], [ "test_data", nil ], [ "election_scope", "Primary" ],
      [ "election_date", "2024-11-05T05:00:00Z" ], [ "election_type", "State House" ],
      [ "district", "GA-02" ], [ "district", "AL-52" ], [ "district", "AL-AL" ],
      [ "municipality", "Birmingham" ] ].each do |key, value|
      assert_raises(Error, "must reject #{key}=#{value.inspect}") { parser.parse(fixture.merge(key => value)) }
    end
  end

  def test_rejects_invalid_votes_candidate_duplicates_and_duplicate_counties
    [ -1, 0.4, nil, "", "NR" ].each do |votes|
      data = fixture
      data["candidates"][0]["votes"] = votes
      assert_raises(Error) { parser.parse(data) }
    end
    data = fixture
    data["candidates"] << data["candidates"].first.dup
    assert_raises(Error) { parser.parse(data) }
    data = fixture
    data["region_results"]["duplicate"] = data["region_results"].values.first.dup
    assert_raises(Error) { parser.parse(data) }
    data = fixture
    data["region_results"].values.first["candidates"][0]["votes"] = -1
    assert_raises(Error) { parser.parse(data) }
  end

  def test_senate_and_at_large_mapping_remain_distinct
    data = fixture("civic_ak_senate.json")
    assert_equal "AK-S", parser("AK").parse(data)["aggregate_units"][0]["race_key"]
    data["election_type"] = "House of Representatives"
    data["district"] = "AK-AL"
    assert_equal "AK-AL", parser("AK").parse(data)["aggregate_units"][0]["race_key"]
    data["district"] = "AK-01"
    assert_raises(Error) { parser("AK").parse(data) }
  end
end
