require "minitest/autorun"

module ElectionNight
  module Sources
  end
end

%w[base arkansas_tally].each do |name|
  require_relative "../../../../app/lib/election_night/sources/#{name}"
end

class ElectionNightArkansasTallyTest < Minitest::Test
  Error = ElectionNight::Sources::Base::InvalidData

  def metadata
    { "electionID" => "general-2026", "lastUpdated" => "2026-11-04T02:30:00Z", "errorMessage" => nil,
      "response" => { "id" => "general-2026", "name" => "2026 General Election & Judicial Runoff", "date" => "2026-11-03T00:00:00",
        "parties" => { "d" => { "partyName" => "Democratic" }, "r" => { "partyName" => "Republican" } },
        "voteTypes" => { "a" => { "voteTypeID" => "a", "description" => "Absentee" },
          "e" => { "voteTypeID" => "e", "description" => "Election Day" }, "v" => { "voteTypeID" => "v", "description" => "Early Voting" },
          "t" => { "voteTypeID" => "t", "description" => "TV - Total Votes" } },
        "locations" => { "05001" => { "locationID" => "05001", "locationName" => "Arkansas", "locations" => {} } } } }
  end

  def choices
    [ [ "alice", "d", [ 5, 15, 40 ] ], [ "bob", "r", [ 10, 10, 20 ] ] ].map do |id, party, counts|
      { "ChoiceID" => id, "Name" => id, "PartyID" => party,
        "Votes" => %w[a e v].zip(counts).map { |type, votes| { "VoteTypeID" => type, "Votes" => votes } } }
    end
  end

  def export
    county = { "ContestID" => "senate", "LocationID" => "05001", "LocationName" => "Arkansas", "Choices" => choices, "WriteinChoices" => [],
      "Locations" => { "precinct" => { "LocationID" => "precinct", "Choices" => choices } } }
    { "ElectionData" => { "ElectionID" => "general-2026", "IsOfficial" => false },
      "ContestData" => [ { "ContestID" => "senate", "ContestName" => "U.S. Senate", "Choices" => choices,
        "Locations" => { "05001" => county } } ] }
  end

  def parser
    ElectionNight::Sources::ArkansasTally.new(state: "AR")
  end

  def test_counts_disjoint_vote_methods_once_at_county_level_using_metadata_parties
    result = parser.parse(JSON.generate(export), metadata: metadata)
    assert_equal 1, result["units"].size
    assert_equal [ "AR-S", "ARKANSAS", 60, 40, 100 ], result["units"][0].values_at("race_key", "unit_key", "dem_votes", "rep_votes", "total_votes")
    assert_equal "2026-11-04T02:30:00Z", result["published_at"]
    house = export
    house["ContestData"][0]["ContestName"] = "U.S. Congress District 02"
    assert_equal "AR-02", parser.parse(house, metadata: metadata)["units"][0]["race_key"]
  end

  def test_requires_matching_current_general_election_and_known_county
    assert_raises(ArgumentError) { parser.parse(export) }
    wrong = metadata
    wrong["response"]["date"] = "2024-11-05T00:00:00"
    assert_raises(Error) { parser.parse(export, metadata: wrong) }
    wrong = metadata
    wrong["response"]["id"] = "other-election"
    assert_raises(Error) { parser.parse(export, metadata: wrong) }
    wrong = metadata
    wrong["response"]["name"] += " TEST"
    assert_raises(Error) { parser.parse(export, metadata: wrong) }
    wrong = metadata
    wrong["response"]["locations"] = {}
    assert_raises(Error) { parser.parse(export, metadata: wrong) }
  end

  def test_rejects_missing_negative_unknown_or_overlapping_vote_components
    [ :negative, :missing, :duplicate, :unknown, :overlap ].each do |problem|
      data = export
      votes = data["ContestData"][0]["Locations"]["05001"]["Choices"][0]["Votes"]
      case problem
      when :negative then votes[0]["Votes"] = -1
      when :missing then votes.pop
      when :duplicate then votes << votes[0].dup
      when :unknown then votes[0]["VoteTypeID"] = "unknown"
      when :overlap then votes << { "VoteTypeID" => "t", "Votes" => 60 }
      end
      assert_raises(Error, problem.to_s) { parser.parse(data, metadata: metadata) }
    end
    data = export
    data["ContestData"][0]["Locations"]["05001"]["Choices"].pop
    assert_raises(Error) { parser.parse(data, metadata: metadata) }
  end

  def test_total_only_is_permitted_without_adding_method_counts
    data = export
    data["ContestData"][0]["Locations"]["05001"]["Choices"].each do |choice|
      choice["Votes"] = [ { "VoteTypeID" => "t", "Votes" => 123 } ]
    end
    assert_equal 246, parser.parse(data, metadata: metadata)["units"][0]["total_votes"]
  end
end
