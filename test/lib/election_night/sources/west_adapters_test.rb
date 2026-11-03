require "minitest/autorun"

module ElectionNight
  module Sources
  end
end

require_relative "../../../../app/lib/election_night/summary_json"
%w[base enhanced_voting california washington alaska_summary].each do |name|
  require_relative "../../../../app/lib/election_night/sources/#{name}"
end

class ElectionNightWestAdaptersTest < Minitest::Test
  Error = ElectionNight::Sources::Base::InvalidData

  def california_metadata
    "This file lists all available JSON endpoints for the California November 3, 2026 Statewide General Election\nhttps://media.sos.ca.gov/media/us-rep.json\n"
  end

  def california_rows
    candidates = [ { "Name" => "Alice", "Party" => "Dem", "Votes" => "1,234" }, { "Name" => "Bob", "Party" => "Rep", "Votes" => "900" } ]
    [ "Districtwide", "Fresno County" ].map do |name|
      { "raceTitle" => "United States Representative District 22 - #{name} Results", "ReportingTime" => "November 3, 2026, 8:30 p.m.", "candidates" => candidates }
    end
  end

  def test_california_counts_county_portions_without_districtwide_double_count
    result = ElectionNight::Sources::California.new(state: "CA").parse(california_rows, metadata: california_metadata)
    assert_equal 1, result["units"].size
    assert_equal [ "CA-22", "FRESNO", 1_234, 2_134, false ], result["units"].first.values_at("race_key", "unit_key", "dem_votes", "total_votes", "complete")
    assert_nil result["published_at"]
  end

  def test_california_requires_dated_companion_metadata_and_valid_candidate_counts
    parser = ElectionNight::Sources::California.new(state: "CA")
    assert_raises(ArgumentError) { parser.parse(california_rows) }
    assert_raises(Error) { parser.parse(california_rows, metadata: california_metadata.sub("November 3, 2026", "November 5, 2024")) }
    assert_raises(Error) { parser.parse(california_rows, metadata: "unidentified election") }
    assert_raises(Error) { parser.parse(california_rows, metadata: california_metadata + "TEST") }
    rows = california_rows
    rows[1]["candidates"][0]["Votes"] = "1,23"
    assert_raises(Error) { parser.parse(rows, metadata: california_metadata) }
    assert_raises(Error) { parser.parse(california_rows * 2, metadata: california_metadata) }
  end

  def washington_export
    { "electionDate" => "2026-11-03", "electionName" => "2026 General", "createdAt" => "2026-11-04T04:00:00Z",
      "results" => { "name" => "Washington", "ballotItems" => [] }, "localResults" => [ { "name" => "Spokane County",
        "ballotItems" => [ { "id" => "cd5", "name" => "Congressional District 5 - U.S. Representative",
          "ballotOptions" => [ { "id" => "a", "politicalParty" => "(Prefers Democratic Party)", "voteCount" => 60 },
            { "id" => "b", "politicalParty" => "(Prefers Republican Party)", "voteCount" => 40 },
            { "id" => "w", "politicalParty" => nil, "voteCount" => 2 } ] } ] } ] }
  end

  def test_washington_understands_congressional_labels_and_candidate_party_preferences
    result = ElectionNight::Sources::Washington.new(state: "WA").parse(washington_export)
    assert_equal [ "WA-05", "SPOKANE", 60, 40, 2 ], result["units"].first.values_at("race_key", "unit_key", "dem_votes", "rep_votes", "other_votes")
    assert_equal "2026-11-04T04:00:00Z", result["published_at"]
    assert_raises(Error) { ElectionNight::Sources::Washington.new(state: "WA").parse(washington_export.merge("isTest" => true)) }
  end

  def alaska_text
    <<~TEXT
      State of Alaska
      2026 GENERAL ELECTION
      Election Summary Report
      November 3, 2026
      UNOFFICIAL RESULTS
      U.S. Senator
      Precincts Reported: 401 of 401 (100.00%)
      Candidate                       Party        Total
      Peltola, Mary                   DEM          1,200       60.00%
      Sullivan, Dan S.                REP            800       40.00%
      Sullivan, Daniel J. Jr.                         10        0.50%
      Total Votes                                 2,010
      U.S. Representative
      Candidate                       Party        Total
      Begich, Nick                    REP            800       40.00%
      Hill, Bill                      NON          1,100       55.00%
      Hafner, Eric                    DEM            100        5.00%
      Write-in                                         0        N/A
      Total Votes                                 2,000
    TEXT
  end

  def test_alaska_first_choice_pdf_text_preserves_unknown_and_independent_votes
    result = ElectionNight::Sources::AlaskaSummary.new(state: "AK").send(:parse_text, alaska_text)
    senate = result["units"].find { |unit| unit["race_key"] == "AK-S" }
    house = result["units"].find { |unit| unit["race_key"] == "AK-AL" }
    assert_equal 10, senate["other_votes"]
    assert_equal 1_100, house["other_votes"]
    assert result["units"].all? { |unit| unit["aggregate_only"] && unit["first_choice_only"] && !unit["complete"] }
  end

  def test_alaska_rejects_wrong_dates_test_data_missing_contests_or_total_mismatches
    parser = ElectionNight::Sources::AlaskaSummary.new(state: "AK")
    assert_raises(Error) { parser.parse("not a PDF") }
    assert_raises(Error) { parser.send(:parse_text, alaska_text.sub("November 3, 2026", "November 5, 2024")) }
    assert_raises(Error) { parser.send(:parse_text, alaska_text + "\nTEST") }
    assert_raises(Error) { parser.send(:parse_text, alaska_text.sub("2,010", "2,011")) }
    assert_raises(Error) { parser.send(:parse_text, alaska_text.sub("U.S. Senator", "State Senate")) }
  end
end
