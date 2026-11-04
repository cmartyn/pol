require "minitest/autorun"

module ElectionNight
  module Sources
  end
end

require_relative "../../../../app/lib/election_night/summary_json"
%w[base enhanced_voting new_york_county clarity_county maryland_house].each do |name|
  require_relative "../../../../app/lib/election_night/sources/#{name}"
end

class ElectionNightNortheastAdaptersTest < Minitest::Test
  Error = ElectionNight::Sources::Base::InvalidData

  def fixture(name)
    File.read(File.expand_path("../../../fixtures/files/election_night/northeast/#{name}", __dir__))
  end

  def test_real_rockland_scaffold_and_fusion_lines_count_each_ballot_once
    parser = ElectionNight::Sources::NewYorkCounty.new(state: "NY")
    assert_equal [ "NY-17" ], parser.parse(fixture("rockland_summary.json"))["units"].map { |u| u["race_key"] }
    data = JSON.parse(fixture("rockland_summary.json"))
    candidates = data["results"]["ballotItems"][0]["ballotOptions"]
    candidates.zip([ 100, 80, 20, 10, 3 ]).each { |candidate, votes| candidate["voteCount"] = votes }
    unit = parser.parse(data)["units"].first
    assert_equal "ROCKLAND", unit["unit_key"]
    assert_equal 110, unit["dem_votes"]
    assert_equal 100, unit["rep_votes"]
    assert_equal 3, unit["other_votes"]
    assert_equal 213, unit["total_votes"]
    refute unit["complete"]
  end

  def test_fusion_does_not_assign_all_minor_party_votes_to_major_parties
    data = JSON.parse(fixture("rockland_summary.json"))
    candidates = data["results"]["ballotItems"][0]["ballotOptions"]
    candidates[2]["name"] = "CON Different Person"
    candidates[2]["voteCount"] = 7
    unit = ElectionNight::Sources::NewYorkCounty.new(state: "NY").parse(data)["units"].first
    assert_equal 7, unit["other_votes"]
    assert_equal 0, unit["rep_votes"]
    assert_raises(Error) { ElectionNight::Sources::NewYorkCounty.new(state: "PA").parse(data) }
  end

  def test_real_clarity_county_scaffold_and_candidate_totals
    parser = ElectionNight::Sources::ClarityCounty.new(state: "NJ")
    data = JSON.parse(fixture("atlantic_summary.json"))
    data[1]["V"] = [ 60, 40, 5 ]
    data[1]["TV"] = 105
    data[1]["PR"] = data[1]["TP"]
    units = parser.parse(data, metadata: fixture("atlantic_metadata.json"))["units"]
    assert_equal [ "NJ-02", "NJ-S" ], units.map { |u| u["race_key"] }
    assert_equal "ATLANTIC", units[0]["unit_key"]
    assert_equal 105, units[0]["total_votes"]
    assert_equal 5, units[0]["other_votes"]
    refute units[0]["complete"], "all precincts reporting does not prove all ballots counted"
  end

  def test_clarity_rejects_test_dates_state_mismatches_and_inconsistent_totals
    parser = ElectionNight::Sources::ClarityCounty.new(state: "NJ")
    original = JSON.parse(fixture("atlantic_metadata.json"))
    [ [ "istestmode", "1" ], [ "showtestdatawatermark", "1" ], [ "electiondate", "10/29/2026" ] ].each do |key, value|
      metadata = Marshal.load(Marshal.dump(original))
      metadata["settings"]["electiondetails"][key] = value
      assert_raises(Error) { parser.parse(fixture("atlantic_summary.json"), metadata: metadata) }
    end
    assert_raises(Error) { parser.parse(fixture("atlantic_summary.json"), metadata: original.merge("parententityname" => "pa")) }
    data = JSON.parse(fixture("atlantic_summary.json"))
    data[0]["TV"] = 1
    assert_raises(Error) { parser.parse(data, metadata: original) }
    data[0]["TV"] = 0
    data[0]["V"][0] = -1
    assert_raises(Error) { parser.parse(data, metadata: original) }
  end

  def test_clarity_handles_observed_county_congressional_labels_without_state_house
    parser = ElectionNight::Sources::ClarityCounty.new(state: "NJ")
    [ "HOUSE OF REPRESENTATIVES - CD 2", "HOUSE OF REPRESENTATIVES 2ND CONGRESSIONAL DISTRICT" ].each do |label|
      data = JSON.parse(fixture("atlantic_summary.json"))
      data[1]["C"] = label
      data[1]["CAT"] = "State"
      assert_equal [ "NJ-02", "NJ-S" ], parser.parse(data, metadata: fixture("atlantic_metadata.json"))["units"].map { |u| u["race_key"] }
    end
    data = JSON.parse(fixture("atlantic_summary.json"))
    data[1]["C"] = "State House District 2"
    assert_equal [ "NJ-S" ], parser.parse(data, metadata: fixture("atlantic_metadata.json"))["units"].map { |u| u["race_key"] }
  end

  def test_maryland_real_nr_scaffold_preserves_unknowns
    result = ElectionNight::Sources::MarylandHouse.new(state: "MD").parse(fixture("maryland_house.html"))
    assert_empty result["units"]
    assert_equal (1..8).map { |n| "MD-#{format('%02d', n)}" }, result["unavailable_races"].keys
    assert_match(/not reported/, result["unavailable_races"]["MD-01"])
  end

  def test_maryland_reads_total_column_once_and_leaves_other_districts_unknown
    html = Nokogiri::HTML(fixture("maryland_house.html"))
    rows = html.at_css("table").css("tbody tr")
    rows.zip([ "1,000", "800", "4", "6", "1,810" ]).each { |row, total| row.css("td")[6].content = total }
    result = ElectionNight::Sources::MarylandHouse.new(state: "MD").parse(html.to_html)
    unit = result["units"].first
    assert_equal "MD-01", unit["race_key"]
    assert_equal 1810, unit["total_votes"]
    assert_equal 1000, unit["dem_votes"]
    assert_equal 800, unit["rep_votes"]
    assert_equal 10, unit["other_votes"]
    assert unit["aggregate_only"]
    assert_equal 7, result["unavailable_races"].size
    refute unit["complete"]
    rows.last.css("td")[6].content = "1,811"
    assert_raises(Error) { ElectionNight::Sources::MarylandHouse.new(state: "MD").parse(html.to_html) }
  end

  def test_maryland_rejects_wrong_election_and_broken_scaffold
    parser = ElectionNight::Sources::MarylandHouse.new(state: "MD")
    assert_raises(Error) { parser.parse(fixture("maryland_house.html").sub("2026 Gubernatorial General", "2026 Gubernatorial Primary")) }
    assert_raises(Error) { parser.parse(fixture("maryland_house.html").sub("District 8", "District 9")) }
    assert_raises(Error) { parser.parse("<html>Request blocked</html>") }
  end
end
