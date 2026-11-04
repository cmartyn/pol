require "minitest/autorun"

module ElectionNight
  module Sources
  end
end

%w[base enhanced_voting north_carolina texas iowa_ledger county_baseline ohio florida].each do |name|
  require_relative "../../../../app/lib/election_night/sources/#{name}"
end

class ElectionNightSourceAdaptersTest < Minitest::Test
  Error = ElectionNight::Sources::Base::InvalidData

  def option(id, party, votes)
    { "id" => id, "politicalParty" => party, "voteCount" => votes,
      "groupResults" => [ { "groupName" => "Election Day", "voteCount" => votes } ] }
  end

  def ev_export
    contest = { "id" => "US2", "name" => "US Senate", "precinctsReporting" => 10,
      "precinctsParticipating" => 10, "ballotOptions" => [ option("a", "Dem", 60), option("b", "Rep", 40) ] }
    { "electionDate" => "2026-11-03", "electionName" => "General Election", "createdAt" => "2026-11-04T02:00:00Z",
      "results" => { "name" => "Georgia", "ballotItems" => [ contest ] },
      "localResults" => [ { "name" => "Fulton County", "ballotItems" => [ contest ] } ] }
  end

  def test_enhanced_voting_counts_county_totals_once_not_summary_or_vote_method_subtotals
    result = ElectionNight::Sources::EnhancedVoting.new(state: "GA").parse(ev_export)
    assert_equal 1, result["units"].length
    assert_equal({ "race_key" => "GA-S", "unit_key" => "FULTON", "dem_votes" => 60,
      "rep_votes" => 40, "other_votes" => 0, "total_votes" => 100, "complete" => false }, result["units"].first)
    assert_equal "2026-11-04T02:00:00Z", result["published_at"]
  end

  def test_enhanced_voting_handles_county_host_and_congressional_naming_variants
    data = ev_export
    data["localResults"] = []
    data["results"]["name"] = "Kent County"
    data["results"]["ballotItems"][0]["name"] = "Representative in Congress 3rd District"
    assert_equal "MI-03", ElectionNight::Sources::EnhancedVoting.new(state: "MI").parse(data)["units"][0]["race_key"]
    data["results"]["ballotItems"][0]["name"] = "Member, House of Representatives (10th District)"
    assert_equal "VA-10", ElectionNight::Sources::EnhancedVoting.new(state: "VA").parse(data)["units"][0]["race_key"]
    data["results"]["ballotItems"][0]["name"] = "U.S. Representative in Congress - District No. 6"
    assert_equal "AZ-06", ElectionNight::Sources::EnhancedVoting.new(state: "AZ").parse(data)["units"][0]["race_key"]
  end

  def test_enhanced_voting_rejects_wrong_date_test_flags_duplicate_units_and_invalid_counts
    parser = ElectionNight::Sources::EnhancedVoting.new(state: "GA")
    assert_raises(Error) { parser.parse(ev_export.merge("electionDate" => "2024-11-05")) }
    assert_raises(Error) { parser.parse(ev_export.merge("isTest" => true)) }
    assert_raises(Error) { parser.parse(ev_export.merge("electionName" => "TEST General")) }
    assert_raises(Error) { parser.parse(ev_export.merge("localResults" => [])) }
    data = ev_export
    data["localResults"] *= 2
    assert_raises(Error) { parser.parse(data) }
    [ -1, 0.5, nil, "", "unknown" ].each do |bad|
      data = ev_export
      data["localResults"][0]["ballotItems"][0]["ballotOptions"][0]["voteCount"] = bad
      assert_raises(Error) { parser.parse(data) }
    end
  end

  def test_independent_city_is_not_merged_with_same_named_county
    data = ev_export
    data["localResults"][0]["name"] = "Fairfax County"
    data["localResults"] << data["localResults"][0].merge("name" => "Fairfax City")
    units = ElectionNight::Sources::EnhancedVoting.new(state: "VA").parse(data)["units"]
    assert_equal [ "FAIRFAX", "FAIRFAX CITY" ], units.map { |u| u["unit_key"] }
  end

  def test_baseline_uses_president_not_state_house_and_checks_2024_date
    data = ev_export
    data["electionDate"] = "2024-11-05"
    contest = data["localResults"][0]["ballotItems"][0]
    contest["name"] = "President of the US"
    data["localResults"][0]["ballotItems"] << contest.merge("id" => "state-house", "name" => "State House of Representatives - District 1")
    result = ElectionNight::Sources::EnhancedVoting.new(state: "GA").parse_baselines(data)
    assert_equal "2024-11-05", result["election_date"]
    assert_equal [ "GA-P" ], result["units"].map { |u| u["race_key"] }
    assert_raises(Error) { ElectionNight::Sources::EnhancedVoting.new(state: "GA").parse_baselines(data.merge("electionDate" => "2020-11-03")) }
  end

  def test_historical_house_units_preserve_county_portions_and_normalize_county_aliases
    data = ev_export
    data["electionDate"] = "2024-11-05"
    county = data["localResults"][0]
    county["name"] = "King & Queen County"
    president = county["ballotItems"][0].merge("name" => "President and Vice President")
    house = president.merge("id" => "cd1", "name" => "Member, House of Representatives (1st District)",
      "ballotOptions" => [ option("a", "Dem", 12), option("b", "Rep", 18) ])
    county["ballotItems"] = [ president, house ]
    result = ElectionNight::Sources::EnhancedVoting.new(state: "VA").parse_baselines(data)
    assert_equal 100, result["units"][0]["total_votes"]
    assert_equal "KING AND QUEEN", result["units"][0]["unit_key"]
    assert_equal "VA-01", result["house_units"][0]["race_key"]
    assert_equal 30, result["house_units"][0]["total_votes"], "whole-county president vote must not substitute for district portion"
  end

  def nc_rows(date: "11/03/2026", contest: "US SENATE")
    "County\tElection Date\tPrecinct\tContest Name\tChoice\tChoice Party\tElection Day\tEarly Voting\tTotal Votes\n" \
      "ALAMANCE\t#{date}\t01\t#{contest}\tAlice\tDEM\t20\t40\t60\n" \
      "ALAMANCE\t#{date}\t01\t#{contest}\tBob\tREP\t30\t10\t40\n" \
      "ALAMANCE\t#{date}\t02\t#{contest}\tAlice\tDEM\t20\t10\t30\n"
  end

  def test_nc_aggregates_precincts_using_total_column_only
    unit = ElectionNight::Sources::NorthCarolina.new(state: "NC").parse(nc_rows)["units"].first
    assert_equal "NC-S", unit["race_key"]
    assert_equal 90, unit["dem_votes"]
    assert_equal 130, unit["total_votes"]
    assert_equal false, unit["complete"]
  end

  def test_nc_rejects_wrong_dates_and_duplicate_rows
    parser = ElectionNight::Sources::NorthCarolina.new(state: "NC")
    assert_raises(Error) { parser.parse(nc_rows(date: "11/05/2024")) }
    assert_raises(Error) { parser.parse(nc_rows + nc_rows.lines.last) }
    assert_raises(Error) { parser.parse(nc_rows.sub("\t60\n", "\t-60\n")) }
    baseline = parser.parse_baselines(nc_rows(date: "11/05/2024", contest: "US PRESIDENT"))
    assert_equal "NC-P", baseline["units"][0]["race_key"]
    assert_equal "2024-11-05", baseline["election_date"]
  end

  def test_nc_baseline_contains_actual_congressional_precinct_sums
    presidential = nc_rows(date: "11/05/2024", contest: "US PRESIDENT")
    house = nc_rows(date: "11/05/2024", contest: "US HOUSE OF REPRESENTATIVES DISTRICT 01")
    baseline = ElectionNight::Sources::NorthCarolina.new(state: "NC").parse_baselines(presidential + house.lines.drop(1).join)
    assert_equal [ "NC-P" ], baseline["units"].map { |u| u["race_key"] }
    assert_equal [ "NC-01" ], baseline["house_units"].map { |u| u["race_key"] }
    assert_equal 130, baseline["house_units"][0]["total_votes"]
  end

  def texas_export
    data = { "101" => { "N" => "HARRIS", "Races" => { "1" => { "N" => "U. S. REPRESENTATIVE DISTRICT 7",
      "T" => 103, "C" => { "a" => { "P" => "DEM", "V" => 60, "EV" => 40 },
        "b" => { "P" => "REP", "V" => 40, "EV" => 10 }, "c" => { "P" => "L", "V" => 3 } } } } } }
    { "upload" => Base64.strict_encode64(JSON.generate(data)) }
  end

  def texas_metadata(date = "11032026")
    { "Home" => Base64.strict_encode64(JSON.generate({ "ElecDate" => date, "LastUpdatedTime" => "Nov 3, 2026 20:30:00" })) }
  end

  def test_texas_requires_companion_election_metadata_and_keeps_third_party_votes
    parser = ElectionNight::Sources::Texas.new(state: "TX")
    result = parser.parse(texas_export, metadata: texas_metadata)
    assert_equal "TX-07", result["units"][0]["race_key"]
    assert_equal 103, result["units"][0]["total_votes"]
    assert_equal 3, result["units"][0]["other_votes"]
    assert_nil result["published_at"], "offset-less source time must not become an invented UTC time"
    assert_raises(Error) { parser.parse(texas_export, metadata: texas_metadata("11052024")) }
    assert_raises(Error) { parser.parse({ "upload" => "not base64" }, metadata: texas_metadata) }
    assert_raises(ArgumentError) { parser.parse(texas_export) }
  end

  def iowa_export
    races = ([ "us-senate" ] + (1..4).map { |n| "us-house-#{n}" }).to_h do |id|
      [ id, { "votes" => 120, "countiesReporting" => 99, "countiesTotal" => 99,
        "candidates" => [ { "party" => "Democrat", "votes" => 70 }, { "party" => "Republican", "votes" => 50 } ] } ]
    end
    { "election" => { "date" => "2026-11-03", "key" => "2026-general" }, "races" => races,
      "sosUpdatedAt" => "2026-11-03T20:30:00-06:00", "fetchedAt" => "2026-11-04T02:31:00Z",
      "sourceUrl" => "https://electionresults.iowa.gov/IA/127077/" }
  end

  def test_iowa_alternative_uses_raw_totals_without_turning_reporting_counties_into_completion
    parser = ElectionNight::Sources::IowaLedger.new(state: "IA")
    result = parser.parse(iowa_export)
    assert_equal 5, result["units"].length
    assert result["units"].all? { |u| u["aggregate_only"] && !u["complete"] }
    assert_equal "2026-11-04T02:30:00Z", result["published_at"]
    assert_equal "STATEWIDE", result["units"].find { |u| u["race_key"] == "IA-S" }["unit_key"]
    bad = iowa_export
    bad["races"].delete("us-house-4")
    assert_raises(Error) { parser.parse(bad) }
  end

  def test_historical_compilation_filters_state_checks_sum_and_matches_texas_names
    csv = "state_name,county_fips,county_name,votes_gop,votes_dem,total_votes\n" \
      "Texas,48123,DeWitt County,70,25,100\nArizona,04001,Apache County,20,30,50\n"
    parser = ElectionNight::Sources::CountyBaseline.new(state: "TX")
    result = parser.parse_baselines(csv)
    assert_equal "2024-11-05", result["election_date"]
    assert_equal 1, result["units"].length
    assert_equal "DEWITT", result["units"][0]["unit_key"]
    assert_equal 5, result["units"][0]["other_votes"]
    assert_equal "LASALLE", parser.parse_baselines(csv.sub("DeWitt", "La Salle"))["units"][0]["unit_key"]
    assert_raises(Error) { parser.parse_baselines(csv.sub("70,25,100", "70,25,90")) }
  end

  def ohio_export
    <<~XML
      <ElectionReport xmlns="#{ElectionNight::Sources::Ohio::NAMESPACE}" IsTest="false" GeneratedDate="2026-11-04T01:00:00Z">
        <Code Type="Fips" Value="39"/>
        <PartyCollection><Party ObjectId="dem" Abbreviation="DEM"/><Party ObjectId="rep" Abbreviation="REP"/></PartyCollection>
        <GpUnitCollection>
          <GpUnit ObjectId="county" Name="Adams" Type="County" IsElectoralDistrict="false"/>
          <GpUnit ObjectId="scope" Name="Adams County" Type="County" IsElectoralDistrict="true"/>
          <GpUnit ObjectId="state" Name="Ohio" Type="State" IsElectoralDistrict="false"/>
        </GpUnitCollection>
        <Election Date="2026-11-03">
          <CandidateCollection><Candidate ObjectId="alice"><PartyId>dem</PartyId></Candidate><Candidate ObjectId="bob"><PartyId>rep</PartyId></Candidate></CandidateCollection>
          <ContestCollection><Contest Name="U.S. Senator">
            <BallotSelection><CandidateId>alice</CandidateId><VoteCountsCollection>
              <VoteCounts Type="Total" Count="60"><GpUnitId>county</GpUnitId></VoteCounts>
              <VoteCounts Type="Total" Count="999"><GpUnitId>scope</GpUnitId></VoteCounts>
              <VoteCounts Type="Total" Count="999"><GpUnitId>state</GpUnitId></VoteCounts>
              <VoteCounts Type="Early" Count="50"><GpUnitId>county</GpUnitId></VoteCounts>
            </VoteCountsCollection></BallotSelection>
            <BallotSelection><CandidateId>bob</CandidateId><VoteCountsCollection>
              <VoteCounts Type="Total" Count="40"><GpUnitId>county</GpUnitId></VoteCounts>
            </VoteCountsCollection></BallotSelection>
          </Contest></ContestCollection>
        </Election>
      </ElectionReport>
    XML
  end

  def test_ohio_distinguishes_county_reporting_units_from_electoral_scopes_and_summaries
    parser = ElectionNight::Sources::Ohio.new(state: "OH")
    result = parser.parse(ohio_export)
    assert_equal 1, result["units"].length
    assert_equal [ "OH-S", "ADAMS", 100 ], result["units"][0].values_at("race_key", "unit_key", "total_votes")
    assert_equal "2026-11-04T01:00:00Z", result["published_at"]
    house = parser.parse(ohio_export.sub("U.S. Senator", "Representative to Congress - District 01"))
    assert_equal "OH-01", house["units"][0]["race_key"]
  end

  def test_ohio_rejects_test_flags_bad_counts_missing_candidate_counties_and_external_entities
    parser = ElectionNight::Sources::Ohio.new(state: "OH")
    [ "true", "1", "" ].each { |flag| assert_raises(Error) { parser.parse(ohio_export.sub('IsTest="false"', "IsTest=\"#{flag}\"")) } }
    assert_raises(Error) { parser.parse(ohio_export.sub('IsTest="false"', "")) }
    assert_raises(Error) { parser.parse(ohio_export.sub('Date="2026-11-03"', 'Date="2024-11-05"')) }
    assert_raises(Error) { parser.parse(ohio_export.sub('Count="40"', 'Count="-1"')) }
    assert_raises(Error) { parser.parse(ohio_export.sub('<VoteCounts Type="Total" Count="40"><GpUnitId>county</GpUnitId></VoteCounts>', "")) }
    assert_raises(Error) { parser.parse('<!DOCTYPE ElectionReport SYSTEM "https://example.invalid/entity">' + ohio_export) }
  end

  def florida_rows(date: "11/03/2026", code: "USR", name: "Representative in Congress, District 3", district: "003")
    (ElectionNight::Sources::Florida::COLUMNS.join("\t") + "\n") +
      [ [ date, "DEM", code, name, "ALA", "Alachua", district, 'Smith "Ace"', "Alice", "", "60" ],
        [ date, "REP", code, name, "ALA", "Alachua", district, "Jones", "Bob", "", "40" ] ].map { |row| row.join("\t") + "\n" }.join
  end

  def test_florida_parses_official_tab_file_and_historical_district_portions
    parser = ElectionNight::Sources::Florida.new(state: "FL")
    result = parser.parse(florida_rows)
    assert_equal [ "FL-03", "ALACHUA", 100 ], result["units"][0].values_at("race_key", "unit_key", "total_votes")
    assert_nil result["published_at"]
    president = florida_rows(date: "11/05/2024", code: "PRE", name: "President and Vice President", district: "   ")
    house = florida_rows(date: "11/05/2024")
    historical = parser.parse_baselines(president + house.lines.drop(1).join)
    assert_equal "FL-P", historical["units"][0]["race_key"]
    assert_equal "FL-03", historical["house_units"][0]["race_key"]
    assert_equal "2024-11-05", historical["election_date"]
  end

  def test_florida_rejects_wrong_elections_duplicate_counts_bad_votes_and_conflicting_districts
    parser = ElectionNight::Sources::Florida.new(state: "FL")
    assert_raises(Error) { parser.parse(florida_rows(date: "11/05/2024")) }
    assert_raises(Error) { parser.parse(florida_rows + florida_rows.lines.last) }
    assert_raises(Error) { parser.parse(florida_rows.sub("\t60\n", "\t-1\n")) }
    assert_raises(Error) { parser.parse(florida_rows(district: "004")) }
    extra_county = florida_rows.lines[1].sub("ALA\tAlachua", "BAK\tBaker")
    assert_raises(Error) { parser.parse(florida_rows + extra_county) }
  end
end
