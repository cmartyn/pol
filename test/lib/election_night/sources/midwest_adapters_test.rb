require "minitest/autorun"

module ElectionNight
  module Sources
  end
end

%w[base nebraska indiana st_charles].each { |name| require_relative "../../../../app/lib/election_night/sources/#{name}" }

class MidwestAdaptersTest < Minitest::Test
  Error = ElectionNight::Sources::Base::InvalidData

  def ne_metadata
    '<input id="hidElectionDate" value="11/3/2026"><a id="lnkDateHeader"><h1>Unofficial Results</h1><h2>General Election November 3, 2026</h2><div class="last-updated">Results last updated:10/29/2026 10:50 AM CT</div></a>'
  end

  def ne_csv
    CSV.generate do |csv|
      csv << %w[RaceID RaceName PartyCode AreaType AreaNum CandidateID CandidateName CurrentDateTime CandidateVotes VoteFor]
      ElectionNight::Sources::Nebraska::FEDERAL_CONTESTS.each do |id, contest|
        contest[:candidates].each_with_index do |candidate, index|
          name = contest[:key] == "NE-S" ? "For United States Senator - 6 Year Term" : "For Representative in Congress - 2 Year Term"
          party = index.zero? ? "REP" : (contest[:key] == "NE-S" ? "PET" : "DEM")
          csv << [ id, name, party, contest[:area], contest[:district], candidate, "Candidate #{candidate}", "11/3/2026 1:18:35 PM", (index + 1) * 10, "1" ]
        end
      end
    end
  end

  def test_nebraska_uses_only_contest_totals_and_keeps_independent_votes_other
    result = ElectionNight::Sources::Nebraska.new(state: "NE").parse(ne_csv, metadata: ne_metadata)
    assert_equal %w[NE-01 NE-02 NE-03 NE-S], result["units"].map { |u| u["race_key"] }
    assert result["units"].all? { |u| u["aggregate_only"] && u["geography_level"] == "contest" && u["complete"] == false }
    senate = result["units"].last
    assert_equal [ 0, 10, 140, 150 ], senate.values_at("dem_votes", "rep_votes", "other_votes", "total_votes")
    assert_nil result["published_at"], "CSV generation time must not imply a new vote report"
  end

  def test_nebraska_rejects_wrong_election_primary_and_test_metadata
    parser = ElectionNight::Sources::Nebraska.new(state: "NE")
    [ ne_metadata.sub("11/3/2026", "11/5/2024"), ne_metadata.sub("General Election", "Primary Election"), ne_metadata.sub("Unofficial Results", "Test Results") ].each do |metadata|
      assert_raises(Error) { parser.parse(ne_csv, metadata: metadata) }
    end
  end

  def test_nebraska_rejects_missing_duplicate_unknown_candidates_and_wrong_geography
    parser = ElectionNight::Sources::Nebraska.new(state: "NE")
    [ ne_csv.lines.reject.with_index { |_line, index| index == 1 }.join,
      ne_csv + ne_csv.lines[1], ne_csv.sub(",3012,", ",9999,"), ne_csv.sub(",SW,", ",CTY,") ].each do |csv|
      assert_raises(Error) { parser.parse(csv, metadata: ne_metadata) }
    end
  end

  def test_nebraska_rejects_invalid_counts_and_old_export
    parser = ElectionNight::Sources::Nebraska.new(state: "NE")
    [ "-1", "1.5", "", "1,000" ].each do |votes|
      data = CSV.parse(ne_csv, headers: true)
      data[0]["CandidateVotes"] = votes
      assert_raises(Error) { parser.parse(data.to_csv, metadata: ne_metadata) }
    end
    assert_raises(Error) { parser.parse(ne_csv.gsub("11/3/2026 1:18:35 PM", "11/5/2024 1:18:35 PM"), metadata: ne_metadata) }
  end

  def test_nebraska_decodes_binary_utf8_bom_and_rejects_invalid_bytes
    body = ("\uFEFF" + ne_csv.sub("Candidate 3012", "Candidate José")).b
    metadata = (ne_metadata + "<!-- Unofficial — county totals unavailable -->").b
    parser = ElectionNight::Sources::Nebraska.new(state: "NE")

    assert_equal parser.parse(ne_csv, metadata: ne_metadata), parser.parse(body, metadata: metadata)
    assert_equal Encoding::BINARY, body.encoding
    assert_equal Encoding::BINARY, metadata.encoding
    assert body.start_with?("\xEF\xBB\xBF".b)
    assert_raises(Error) { parser.parse(body + "\xFF".b, metadata: metadata) }
    assert_raises(Error) { parser.parse(body, metadata: metadata + "\xFF".b) }
  end

  def in_metadata
    { "Root" => { "CurrentElection" => "11/03/2026", "StateFP" => "18", "ElectionType" => "G", "VersionType" => "B", "WriteTime" => "2026-11-03T20:12:50.000" } }
  end

  def in_export
    summaries = (1..9).map do |district|
      { "OFFICEID" => district.to_s, "SubSortOrder" => "United States Representative, (#{district}) District", "NumofSeats" => "1",
        "Candidates" => { "Candidate" => [ { "NAME_ON_BALLOT" => "D #{district}", "PARTY" => "D", "TOTAL" => 60 }, { "NAME_ON_BALLOT" => "R #{district}", "PARTY" => "R", "TOTAL" => 40 } ] } }
    end
    regions = summaries.map.with_index(1) do |summary, district|
      county = Marshal.load(Marshal.dump(summary))
      county["Jurisdiction"] = { "FIPS" => "18#{format('%03d', district)}", "JURISDICTION_TYPE" => "Locality", "JURISDICTION_NAME" => "County #{district}" }
      county["Candidates"]["Candidate"].each { |c| c["PARTY_ABBREV"] = c.delete("PARTY"); c["TOTAL_VOTES"] = c.delete("TOTAL") }
      { "MAP_JURISDICTION_TYPE" => "District", "MAP_JURISDICTION_NAME" => district.to_s,
        "RegionSummary" => { "Race" => summary }, "Races" => { "Race" => [ county ] } }
    end
    { "Root" => { "WriteTime" => "2026-11-03T20:12:46.77", "StatewideSummary" => { "Race" => summaries },
      "OfficeCategory" => { "OFFICECATEGORYID" => "1005", "OFFICE_CATEGORY_NAME" => "US Representative", "Regions" => { "Region" => regions } } } }
  end

  def test_indiana_uses_county_votes_once_and_checks_both_district_summary_copies
    result = ElectionNight::Sources::Indiana.new(state: "IN").parse(in_export, metadata: in_metadata)
    assert_equal 9, result["units"].size
    assert_equal 900, result["units"].sum { |u| u["total_votes"] }
    assert_equal "2026-11-04T01:12:46Z", result["published_at"]
    assert result["units"].all? { |u| u["complete"] == false && !u["aggregate_only"] }
  end

  def test_indiana_rejects_wrong_election_state_test_and_unknown_version
    parser = ElectionNight::Sources::Indiana.new(state: "IN")
    [ [ "CurrentElection", "05/05/2026" ], [ "StateFP", "39" ], [ "ElectionType", "P" ], [ "VersionType", "../A" ], [ "IsTest", true ] ].each do |field, value|
      metadata = in_metadata
      metadata["Root"][field] = value
      assert_raises(Error) { parser.parse(in_export, metadata: metadata) }
    end
  end

  def test_indiana_rejects_duplicate_missing_and_wrong_districts
    parser = ElectionNight::Sources::Indiana.new(state: "IN")
    [ :duplicate, :missing, :wrong ].each do |mutation|
      data = in_export
      regions = data["Root"]["OfficeCategory"]["Regions"]["Region"]
      regions << regions.first if mutation == :duplicate
      regions.pop if mutation == :missing
      regions.first["MAP_JURISDICTION_NAME"] = "10" if mutation == :wrong
      assert_raises(Error) { parser.parse(data, metadata: in_metadata) }
    end
  end

  def test_indiana_rejects_duplicated_state_summary_even_when_counts_match
    data = in_export
    summaries = data["Root"]["StatewideSummary"]["Race"]
    summaries << summaries.first
    assert_raises(Error) { ElectionNight::Sources::Indiana.new(state: "IN").parse(data, metadata: in_metadata) }
  end

  def test_indiana_rejects_duplicate_county_missing_candidate_and_inconsistent_totals
    parser = ElectionNight::Sources::Indiana.new(state: "IN")
    [ :duplicate, :missing_candidate, :total, :bad_votes ].each do |mutation|
      data = in_export
      counties = data["Root"]["OfficeCategory"]["Regions"]["Region"][0]["Races"]["Race"]
      candidates = counties.first["Candidates"]["Candidate"]
      counties << counties.first if mutation == :duplicate
      candidates.pop if mutation == :missing_candidate
      candidates.first["TOTAL_VOTES"] = 61 if mutation == :total
      candidates.first["TOTAL_VOTES"] = 60.0 if mutation == :bad_votes
      assert_raises(Error) { parser.parse(data, metadata: in_metadata) }
    end
  end

  def test_indiana_rejects_old_or_mismatched_generation_time
    parser = ElectionNight::Sources::Indiana.new(state: "IN")
    [ "2024-11-05T20:12:46", "2026-11-04T20:12:46", "2026-11-03T20:12:46+05:00" ].each do |time|
      data = in_export
      data["Root"]["WriteTime"] = time
      assert_raises(Error) { parser.parse(data, metadata: in_metadata) }
    end
  end

  def mo_metadata
    '<h1 class="election-title">November 3, 2026 General Election</h1><span>St. Charles County Election Authority</span>'
  end

  def mo_csv
    "Unofficial election results\nSt. Charles County\n" + CSV.generate do |csv|
      csv << [ "Contest Name", "Candidate Name", "Party", "Absentee Votes", "Election Day Votes", "Provisional Votes", "Total Votes" ]
      ElectionNight::Sources::StCharles::CANDIDATES.each do |key, names|
        names.each_with_index do |name, index|
          party = [ "REPUBLICAN PARTY", "DEMOCRATIC PARTY", "LIBERTARIAN PARTY", "" ][index]
          csv << [ "US REPRESENTATIVE DISTRICT #{key[-1]}", name, party, 2, 3, 1, 6 ]
        end
      end
    end
  end

  def test_st_charles_is_county_detail_and_votes_are_not_added_again_from_vote_methods
    result = ElectionNight::Sources::StCharles.new(state: "MO").parse(mo_csv, metadata: mo_metadata)
    assert_equal %w[MO-02 MO-03], result["units"].map { |unit| unit["race_key"] }
    assert_equal [ "ST. CHARLES" ], result["units"].map { |unit| unit["unit_key"] }.uniq
    assert_equal [ 6, 6, 12, 24 ], result["units"].first.values_at("dem_votes", "rep_votes", "other_votes", "total_votes")
  end

  def test_st_charles_rejects_wrong_election_missing_candidate_and_inconsistent_count
    parser = ElectionNight::Sources::StCharles.new(state: "MO")
    assert_raises(Error) { parser.parse(mo_csv, metadata: mo_metadata.sub("November 3, 2026", "August 4, 2026")) }
    assert_raises(Error) { parser.parse(mo_csv, metadata: mo_metadata.sub("General Election", "Test General Election")) }
    assert_raises(Error) { parser.parse(mo_csv.lines[0...-1].join, metadata: mo_metadata) }
    assert_raises(Error) { parser.parse(mo_csv.sub(",2,3,1,6", ",2,3,1,9"), metadata: mo_metadata) }
    assert_raises(Error) { parser.parse(mo_csv + mo_csv.lines[3], metadata: mo_metadata) }
  end

  def test_st_charles_decodes_binary_http_bodies_with_utf8_bom_without_mutating_archive_bytes
    body = ("\uFEFF" + mo_csv).b
    metadata = (mo_metadata + "<!-- Unofficial — county portions -->").b
    parser = ElectionNight::Sources::StCharles.new(state: "MO")

    assert_equal parser.parse(mo_csv, metadata: mo_metadata), parser.parse(body, metadata: metadata)
    assert_equal Encoding::BINARY, body.encoding
    assert_equal Encoding::BINARY, metadata.encoding
    assert body.start_with?("\xEF\xBB\xBF".b)
  end

  def test_st_charles_rejects_invalid_utf8_instead_of_replacing_source_bytes
    parser = ElectionNight::Sources::StCharles.new(state: "MO")
    assert_raises(Error) { parser.parse(mo_csv.b + "\xFF".b, metadata: mo_metadata.b) }
    assert_raises(Error) { parser.parse(mo_csv.b, metadata: mo_metadata.b + "\xFF".b) }
  end
end
