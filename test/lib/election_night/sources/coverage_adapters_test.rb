require "minitest/autorun"
require "yaml"
module ElectionNight
  module Sources
  end
end
require_relative "../../../../app/lib/election_night/sources/base"
require_relative "../../../../app/lib/election_night/sources/polling_desk"
require_relative "../../../../app/lib/election_night/sources/louisiana_senate"

class ElectionNightCoverageAdaptersTest < Minitest::Test
  Error = ElectionNight::Sources::Base::InvalidData

  def national_rows
    house = CSV.read(File.expand_path("../../../../db/seed_data/house_baselines/2026/presidential_2024.csv", __dir__), headers: true)
    senate = YAML.safe_load_file(File.expand_path("../../../../db/seed_data/senate_2026.yml", __dir__))
    house.map { |r| [ r["state"], "house", r["district"] ] }.concat(senate.map { |r| [ r["state"], "senate", "" ] }).map do |state, office, district|
      { "cycle" => "2026", "office" => office, "state" => state, "district" => district,
        "race_key" => "2026/#{office}/#{state.downcase}#{office == 'house' ? format('-%02d', district.to_i) : ''}",
        "candidate" => "Candidate", "party" => "DEM", "votes" => "11", "results_updated_utc" => "2026-11-04 01:02:03",
        "source" => "civicAPI (civicapi.org)", "winner" => "yes", "percent_reporting" => "100", "percent" => "100" }
    end
  end

  def csv(rows)
    CSV.generate do |out|
      out << rows.first.keys
      rows.each { |row| out << row.values }
    end
  end

  def test_national_totals_are_raw_aggregate_only_and_calls_are_discarded
    result = ElectionNight::Sources::PollingDesk.new(state: "US").parse(csv(national_rows))
    assert_equal 470, result["units"].size
    assert result["units"].all? { |u| u["aggregate_only"] && u["complete"] == false && u["total_votes"] == 11 }
    assert_includes result["units"].map { |u| u["race_key"] }, "AK-AL"
    assert_nil result["units"].first["winner"]
    assert_nil result["units"].first["percent_reporting"]
    assert_includes result["election_date_basis"], "no explicit election-date"
  end

  def test_national_catalog_rejects_missing_contests_bad_counts_and_duplicate_candidates
    parser = ElectionNight::Sources::PollingDesk.new(state: "US")
    rows = national_rows
    assert_raises(Error) { parser.parse(csv(rows.drop(1))) }
    assert_raises(Error) { parser.parse(csv(rows + [ rows.first ])) }
    %w[-1 2.5 NR].each do |value|
      invalid = rows.map(&:dup)
      invalid.first["votes"] = value
      assert_raises(Error) { parser.parse(csv(invalid)) }
    end
    rows.first["cycle"] = "2024"
    assert_raises(Error) { parser.parse(csv(rows)) }
  end

  def test_national_catalog_rejects_same_size_wrong_state_or_district
    parser = ElectionNight::Sources::PollingDesk.new(state: "US")
    [ [ "house", "ZZ", "1" ], [ "house", "DE", "2" ], [ "senate", "CA", "" ] ].each do |office, state, district|
      rows = national_rows
      replacement = rows.find { |row| row["office"] == office }
      replacement.merge!("state" => state, "district" => district,
        "race_key" => "2026/#{office}/#{state.downcase}#{office == 'house' ? format('-%02d', district.to_i) : ''}")
      assert_equal 470, rows.size
      assert_raises(Error) { parser.parse(csv(rows)) }
    end
  end

  def la_metadata(date = "11/03/2026")
    { "Dates" => { "Date" => [ { "PKElectionID" => "344", "ElectionDate" => date } ] } }
  end

  def la_csv(size = 64)
    CSV.generate do |out|
      out << [ "Office", "Parish", '"Jamie" Davis (DEM)', "Julia Letlow (REP)" ]
      size.times { |i| out << [ "U. S. Senator", "Parish #{i}", 60, 40 ] }
    end
  end

  def test_louisiana_counts_parishes_once_and_requires_current_election
    parser = ElectionNight::Sources::LouisianaSenate.new(state: "LA")
    result = parser.parse(la_csv, metadata: la_metadata)
    assert_equal 64, result["units"].size
    assert_equal 6_400, result["units"].sum { |u| u["total_votes"] }
    assert result["units"].all? { |u| !u["complete"] }
    assert_raises(Error) { parser.parse(la_csv(63), metadata: la_metadata) }
    assert_raises(Error) { parser.parse(la_csv, metadata: la_metadata("11/05/2024")) }
  end
end
