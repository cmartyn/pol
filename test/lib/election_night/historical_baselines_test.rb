require "minitest/autorun"
require "tmpdir"
require "fileutils"

module ElectionNight
  module Sources
  end
end

require_relative "../../../app/lib/election_night/sources/base"
require_relative "../../../app/lib/election_night/historical_baselines"

class ElectionNightHistoricalBaselinesTest < Minitest::Test
  def historical
    @historical ||= ElectionNight::HistoricalBaselines.new.call
  end

  def test_frozen_coverage_and_provenance_are_complete_for_claimed_races
    assert_equal 49, historical.fetch("state_manifests").size
    assert_equal 3111, historical.fetch("units").size
    assert_equal 419, historical.fetch("house_manifests").size
    assert_equal 3621, historical.fetch("house_units").size
    assert_equal 5059, historical.fetch("turnout_2022").size
    refute historical.fetch("state_manifests").key?("AK")
    assert_equal 133, historical.fetch("state_manifests").fetch("VA").size
    assert_equal 8, historical.fetch("state_manifests").fetch("CT").size
    assert_equal 4, historical.fetch("state_manifests").fetch("HI").size
    assert_empty historical.fetch("unverified_state_manifests")
    assert historical.fetch("units").all? { |row| row.fetch("source_ids").any? && row.fetch("source_url").start_with?("https://") }
    assert_equal 64, historical.fetch("revision").size
  end

  def test_house_portions_remain_district_specific_and_zero_cross_product_is_not_geography
    rows = historical.fetch("house_units").select { |row| row["state"] == "NC" && row["unit_key"] == "WAKE" }
    assert_operator rows.size, :>, 1
    assert_equal 405517, rows.find { |row| row["race_key"] == "NC-02" }.fetch("total_votes")
    assert_equal 102363, rows.find { |row| row["race_key"] == "NC-13" }.fetch("total_votes")
    assert rows.all? { |row| row.fetch("district_portion") }
    assert_equal [ "FRANKLIN" ], historical.fetch("house_manifests").fetch("OH-03")
    assert historical.fetch("house_units").all? { |row| row.fetch("total_votes").positive? }
  end

  def test_fusion_votes_follow_candidate_without_reclassifying_independent_opponents
    ny = historical.fetch("house_units").select { |row| row["race_key"] == "NY-18" }
    assert_equal 207106, ny.sum { |row| row.fetch("dem_votes") }
    assert_equal 155129, ny.sum { |row| row.fetch("rep_votes") }
    ct = historical.fetch("house_units").select { |row| row["race_key"] == "CT-05" }
    assert_equal 180268, ct.sum { |row| row.fetch("dem_votes") }
    assert_equal 157258, ct.sum { |row| row.fetch("rep_votes") }
  end

  def test_materially_incomplete_races_are_not_exposed_and_presidential_repairs_are_attributed
    %w[MO-05 NY-25 OR-05].each { |race| refute historical.fetch("house_manifests").key?(race) }
    jackson = historical.fetch("units").find { |row| row["county_fips"] == "29095" }
    assert_equal 187026, jackson.fetch("dem_votes")
    assert_equal 125610, jackson.fetch("rep_votes")
    assert_equal [ "tonmcg:president:2024" ], jackson.fetch("source_ids")
    assert_includes historical.dig("provenance", "excluded_races", "house_2024"), "MO-05"
  end

  def test_current_line_totals_are_aggregate_only_and_do_not_add_county_manifests
    rows = historical.fetch("house_totals_current_lines")
    assert_equal 435, rows.size
    assert rows.all? { |row| row["aggregate_only"] && row["geography_level"] == "contest" && row["geography_year"] == 2026 }
    assert_equal "AK-AL", rows.find { |row| row["state"] == "AK" }.fetch("race_key")
    refute historical.fetch("house_manifests").key?("AK-AL")
    assert rows.all? { |row| row.values_at("dem_votes", "rep_votes", "other_votes").sum == row.fetch("total_votes") }
    provenance = historical.dig("provenance", "current_lines_catalog")
    assert_equal Digest::SHA256.file(File.join(ElectionNight::HistoricalBaselines::CURRENT_LINES_DIRECTORY, "presidential_2024.csv")).hexdigest, provenance.fetch("data_sha256")
    assert_equal Digest::SHA256.file(File.join(ElectionNight::HistoricalBaselines::CURRENT_LINES_DIRECTORY, "manifest.yml")).hexdigest, provenance.fetch("manifest_sha256")
    assert provenance.fetch("aggregate_only")
    assert_equal rows.first.fetch("source_revision"), provenance.fetch("source_revision")
  end

  def test_historical_revision_changes_when_current_line_totals_change
    Dir.mktmpdir("current-line-history") do |dir|
      FileUtils.cp(Dir[File.join(ElectionNight::HistoricalBaselines::CURRENT_LINES_DIRECTORY, "*")].select { |file| File.file?(file) }, dir)
      original = ElectionNight::HistoricalBaselines.new(current_lines_directory: dir).call
      path = File.join(dir, "presidential_2024.csv")
      table = CSV.read(path, headers: true)
      table[0]["dem_votes"] = (table[0]["dem_votes"].to_i + 1).to_s
      table[0]["total_votes"] = (table[0]["total_votes"].to_i + 1).to_s
      File.write(path, table.to_csv)
      assert_raises(ElectionNight::HistoricalBaselines::Invalid) { ElectionNight::HistoricalBaselines.new(current_lines_directory: dir).call }
      manifest_path = File.join(dir, "manifest.yml")
      manifest = JSON.parse(File.read(manifest_path))
      manifest.fetch("sources").fetch("presidential_2024.csv")["sha256"] = Digest::SHA256.file(path).hexdigest
      File.write(manifest_path, JSON.generate(manifest))
      changed = ElectionNight::HistoricalBaselines.new(current_lines_directory: dir).call
      refute_equal original.fetch("revision"), changed.fetch("revision")
      refute_equal original.dig("provenance", "current_lines_catalog", "manifest_sha256"), changed.dig("provenance", "current_lines_catalog", "manifest_sha256")
      assert_equal original.dig("provenance", "files"), changed.dig("provenance", "files")
    end
  end

  def test_midterm_rows_are_separate_and_do_not_claim_boundary_compatibility
    assert historical.fetch("turnout_2022").all? { |row| row.fetch("geography_year") == 2022 }
    assert historical.fetch("house_units").none? { |row| row.key?("midterm_total_votes") || row.key?("historical_house_compatible") }
    assert_equal 27, historical.fetch("turnout_2022").map { |row| row["race_key"] }.uniq.count { |key| key.end_with?("-S") }
    assert_equal 25, historical.fetch("turnout_state_manifests").size
    assert_equal [ "ID", "NY" ], historical.fetch("unverified_turnout_state_manifests").keys.sort
    assert_equal [ "16077" ], historical.dig("unverified_turnout_state_manifests", "ID", "missing_county_fips")
    assert_equal [ "36015" ], historical.dig("unverified_turnout_state_manifests", "NY", "missing_county_fips")
  end

  def test_checksum_changes_fail_closed
    with_fixture do |dir|
      File.open(File.join(dir, "house_county_2024.csv"), "a") { |file| file.write("\n") }
      error = assert_raises(ElectionNight::HistoricalBaselines::Invalid) { load_fixture(dir) }
      assert_match(/checksum/, error.message)
    end
  end

  def test_independent_roster_withholds_state_even_if_only_a_small_county_is_omitted
    with_fixture do |dir|
      path = File.join(dir, "county_president_2024.csv")
      rows = CSV.read(path, headers: true).map(&:to_h).reject { |row| row["county_fips"] == "48301" } # Loving, TX
      CSV.open(path, "w") do |csv|
        csv << ElectionNight::HistoricalBaselines::COLUMNS
        rows.each { |row| csv << row.values_at(*ElectionNight::HistoricalBaselines::COLUMNS) }
      end
      rehash(dir, "county_president_2024.csv")
      result = load_fixture(dir)
      refute result.fetch("state_manifests").key?("TX")
      assert_equal [ "48301" ], result.dig("unverified_state_manifests", "TX", "missing_county_fips")
      assert result.fetch("state_manifests").key?("NC")
    end
  end

  def test_independent_city_and_obsolete_fips_are_unambiguous
    va = historical.fetch("units").select { |row| row["state"] == "VA" }
    assert_equal "RICHMOND", va.find { |row| row["county_fips"] == "51159" }.fetch("unit_key")
    assert_equal "RICHMOND CITY", va.find { |row| row["county_fips"] == "51760" }.fetch("unit_key")
    sd = historical.fetch("units").find { |row| row["county_fips"] == "46102" }
    assert_equal "OGLALA LAKOTA", sd.fetch("unit_key")
    assert_includes sd.fetch("quality_flags"), "obsolete_fips_46113_corrected_to_46102"
    refute historical.fetch("units").any? { |row| row["county_fips"] == "46113" }
  end

  def test_duplicate_and_invalid_units_fail_even_with_updated_hash
    [ :duplicate, :negative, :wrong_total, :wrong_state, :wrong_year, :unknown_source, :aggregate ].each do |mutation|
      with_fixture do |dir|
        path = File.join(dir, "house_county_2024.csv")
        rows = CSV.read(path, headers: true).map(&:to_h)
        case mutation
        when :duplicate then rows << rows.first.dup
        when :negative then rows.first["dem_votes"] = "-1"
        when :wrong_total then rows.first["total_votes"] = "1"
        when :wrong_state then rows.first["county_fips"] = "99001"
        when :wrong_year then rows.first["geography_year"] = "2022"
        when :unknown_source then rows.first["source_ids"] = "invented"
        when :aggregate then rows.first["race_key"] = "NC-P"
        end
        CSV.open(path, "w") do |csv|
          csv << ElectionNight::HistoricalBaselines::COLUMNS
          rows.each { |row| csv << row.values_at(*ElectionNight::HistoricalBaselines::COLUMNS) }
        end
        rehash(dir, "house_county_2024.csv")
        assert_raises(ElectionNight::HistoricalBaselines::Invalid, mutation.to_s) { load_fixture(dir) }
      end
    end
  end

  private
    def load_fixture(dir)
      ElectionNight::HistoricalBaselines.new(directory: dir, current_lines_directory: nil).call
    end

    def with_fixture
      Dir.mktmpdir("historical-baselines") do |dir|
        FileUtils.cp(Dir[File.join(ElectionNight::HistoricalBaselines::DIRECTORY, "*")].select { |file| File.file?(file) }, dir)
        yield dir
      end
    end

    def rehash(dir, name)
      path = File.join(dir, "manifest.json")
      manifest = JSON.parse(File.read(path))
      manifest.fetch("files").fetch(name)["sha256"] = Digest::SHA256.file(File.join(dir, name)).hexdigest
      if name.end_with?(".csv")
        rows = CSV.read(File.join(dir, name), headers: true)
        manifest.fetch("files").fetch(name)["rows"] = rows.size
        manifest.fetch("files").fetch(name)["races"] = rows.map { |row| row["race_key"] }.uniq.size
      end
      File.write(path, JSON.generate(manifest))
    end
end
