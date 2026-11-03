require "test_helper"

class ElectionNight::CoverageTest < ActiveSupport::TestCase
  test "complete raw feeds, partial results and direct evidence have separate denominators" do
    races = [
      { "race_key" => "MI-S", "raw_coverage_level" => "county", "observed_votes" => 0, "raw_source_ids" => [ "civic" ] },
      { "race_key" => "NE-S", "raw_coverage_level" => "contest", "observed_votes" => 100, "raw_source_ids" => [ "ne" ] },
      { "race_key" => "NY-17", "raw_coverage_level" => "partial", "observed_votes" => 10 },
      { "race_key" => "MD-01", "raw_coverage_level" => "none", "observed_votes" => 0 },
      { "race_key" => "NC-S", "raw_coverage_level" => "county", "observed_votes" => 10000, "direct_observation" => true, "has_baseline" => true }
    ]
    watchlist = { "race_keys" => %w[MI-S NE-S NY-17 MD-01 MN-S] }
    sources = [ { "id" => "civic", "source_kind" => "secondary", "url" => "https://civicapi.org/" },
      { "id" => "ne", "source_kind" => "official", "url" => "https://electionresults.nebraska.gov/" } ]
    coverage = ElectionNight::Coverage.new(races: races, sources: sources, watchlist: watchlist)

    assert_equal({ "races_total" => 5, "races_with_returns" => 1, "races_with_baselines" => 1,
      "races_with_raw_returns" => 3, "races_with_raw_sources" => 3, "competitive_races_total" => 5,
      "competitive_races_with_raw_sources" => 2, "competitive_races_with_county_sources" => 1,
      "competitive_races_with_contest_sources" => 1, "competitive_races_with_partial_sources" => 1 }, coverage.summary)
    report = coverage.report
    assert_equal %w[MD-01 MI-S NC-S NE-S NY-17], report.fetch("races").map { |row| row["race_key"] }
    assert_equal [ "secondary" ], report.fetch("races").find { |row| row["race_key"] == "MI-S" }.fetch("source_kinds")
    assert_equal false, report.fetch("races").find { |row| row["race_key"] == "NC-S" }.fetch("competitive")
    assert_equal [ "https://electionresults.nebraska.gov/" ], report.fetch("races").find { |row| row["race_key"] == "NE-S" }.fetch("source_urls")
  end
end
