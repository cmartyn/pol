require "minitest/autorun"
require_relative "../../../app/lib/election_night/summary_json"

class ElectionNight::SummaryJsonTest < Minitest::Test
  def test_discards_only_unused_detail_while_preserving_summary_votes_and_metadata
    original = {
      "electionDate" => "2026-11-03", "createdAt" => "2026-11-04T03:00:00Z",
      "isProduction" => true, "isTest" => false,
      "localResults" => [ {
        "id" => "01", "name" => "Example County",
        "ballotItems" => [ {
          "id" => "US-SEN", "name" => "US Senate",
          "ballotOptions" => [ {
            "id" => "D-1", "name" => "A Candidate", "politicalParty" => "Democratic", "voteCount" => 123,
            "groupResults" => [ { "groupName" => "Early", "voteCount" => 12 } ],
            "precinctResults" => [ { "id" => "P-1", "voteCount" => 15,
                                    "groupResults" => [ { "groupName" => "Early", "voteCount" => 1 } ] } ]
          }, {
            "id" => "R-1", "name" => "B Candidate", "politicalParty" => "Republican", "voteCount" => 231,
            "precinctResults" => [], "groupResults" => []
          } ]
        } ]
      } ]
    }
    encoded = JSON.generate(original)
    parsed = ElectionNight::SummaryJson.parse(encoded)
    expected = JSON.parse(encoded)
    expected.fetch("localResults").first.fetch("ballotItems").first.fetch("ballotOptions").each do |candidate|
      candidate.delete("precinctResults")
      candidate.delete("groupResults")
    end
    assert_equal expected, parsed
    assert_equal [ 123, 231 ], parsed.fetch("localResults").first.fetch("ballotItems").first.fetch("ballotOptions").map { |c| c.fetch("voteCount") }
    assert_equal encoded, JSON.generate(original)
  end

  def test_invalid_json_in_discarded_details_is_still_rejected
    invalid = '{"voteCount":123,"precinctResults":[{"groupResults":[invalid]}]}'
    assert_raises(JSON::ParserError) { ElectionNight::SummaryJson.parse(invalid) }
  end

  def test_validation_relevant_bad_values_survive_for_the_adapter_to_reject
    parsed = ElectionNight::SummaryJson.parse('{"electionDate":"2024-11-05","isTest":true,"voteCount":-3,"precinctResults":[]}')
    assert_equal "2024-11-05", parsed.fetch("electionDate")
    assert_equal true, parsed.fetch("isTest")
    assert_equal(-3, parsed.fetch("voteCount"))
    refute parsed.key?("precinctResults")
  end
end
