require "csv"
require "digest"
require "json"
require "pathname"

# Frozen raw vote counts and independently historical reporting-unit manifests.
# A manifest is not proof that a current district has the same boundaries. The
# caller must enforce the prior's independent House boundary compatibility gate.
class ElectionNight::HistoricalBaselines
  Invalid = Class.new(StandardError)
  DIRECTORY = File.expand_path("../../../db/seed_data/election_night", __dir__).freeze
  CURRENT_LINES_DIRECTORY = File.expand_path("../../../db/seed_data/house_baselines/2026", __dir__).freeze
  DATASETS = { "units" => [ "county_president_2024.csv", 2024 ],
    "house_units" => [ "house_county_2024.csv", 2024 ], "turnout_2022" => [ "turnout_2022.csv", 2022 ] }.freeze
  STATE_FIPS = %w[AL:01 AK:02 AZ:04 AR:05 CA:06 CO:08 CT:09 DE:10 FL:12 GA:13 HI:15 ID:16 IL:17 IN:18 IA:19 KS:20 KY:21 LA:22 ME:23 MD:24 MA:25 MI:26 MN:27 MS:28 MO:29 MT:30 NE:31 NV:32 NH:33 NJ:34 NM:35 NY:36 NC:37 ND:38 OH:39 OK:40 OR:41 PA:42 RI:44 SC:45 SD:46 TN:47 TX:48 UT:49 VT:50 VA:51 WA:53 WV:54 WI:55 WY:56].to_h { |pair| pair.split(":") }.freeze
  AT_LARGE = %w[AK DE ND SD VT WY].freeze
  COLUMNS = %w[race_key state county_fips county_name dem_votes rep_votes other_votes total_votes geography_year source_ids quality_flags].freeze
  SEATS = { "AL" => 7, "AK" => 1, "AZ" => 9, "AR" => 4, "CA" => 52, "CO" => 8, "CT" => 5,
    "DE" => 1, "FL" => 28, "GA" => 14, "HI" => 2, "ID" => 2, "IL" => 17, "IN" => 9,
    "IA" => 4, "KS" => 4, "KY" => 6, "LA" => 6, "ME" => 2, "MD" => 8, "MA" => 9,
    "MI" => 13, "MN" => 8, "MS" => 4, "MO" => 8, "MT" => 2, "NE" => 3, "NV" => 4,
    "NH" => 2, "NJ" => 12, "NM" => 3, "NY" => 26, "NC" => 14, "ND" => 1, "OH" => 15,
    "OK" => 5, "OR" => 6, "PA" => 17, "RI" => 2, "SC" => 7, "SD" => 1, "TN" => 9,
    "TX" => 38, "UT" => 4, "VT" => 1, "VA" => 11, "WA" => 10, "WV" => 2, "WI" => 8, "WY" => 1 }.freeze

  def initialize(directory: DIRECTORY, current_lines_directory: CURRENT_LINES_DIRECTORY)
    @directory = Pathname.new(directory)
    @current_lines_directory = Pathname.new(current_lines_directory) if current_lines_directory
  end

  def call
    manifest_body = @directory.join("manifest.json").read
    manifest = JSON.parse(manifest_body)
    unless manifest["schema_version"] == 1 && manifest["election_date"] == "2024-11-05" && manifest["midterm_election_date"] == "2022-11-08"
      raise Invalid, "unsupported historical manifest"
    end
    expected_files = DATASETS.values.map(&:first) + %w[source_catalog.json validation.json county_roster.json]
    raise Invalid, "unexpected historical files" unless manifest.fetch("files").keys.sort == expected_files.sort
    manifest.fetch("files").each { |file, info| verify_file!(@directory.join(file), info.fetch("sha256")) }
    @source_catalog = JSON.parse(@directory.join("source_catalog.json").read)
    @known_source_ids = @source_catalog.map { |row| "heideman:#{row.fetch('source')}:#{row.fetch('office')}" } + [ "tonmcg:president:2024" ]
    result = DATASETS.to_h do |key, (filename, year)|
      rows = read_units(filename, year, key)
      info = manifest.fetch("files").fetch(filename)
      unless info.fetch("rows") == rows.size && info.fetch("races") == rows.map { |row| row.fetch("race_key") }.uniq.size
        raise Invalid, "historical row/race count mismatch: #{filename}"
      end
      [ key, rows ]
    end
    verified, unverified = verified_state_manifests(result.fetch("units"))
    turnout_verified, turnout_unverified = verified_state_manifests(result.fetch("turnout_2022").select { |row| row.fetch("race_key").end_with?("-S") })
    current_totals = current_line_totals
    provenance = manifest.merge("source_catalog" => @source_catalog)
    provenance["current_lines_catalog"] = @current_lines_provenance if @current_lines_provenance
    revisions = [ Digest::SHA256.hexdigest(manifest_body), @current_lines_provenance&.fetch("manifest_sha256") ].compact
    result.merge!("election_date" => manifest.fetch("election_date"),
      "state_manifests" => verified, "unverified_state_manifests" => unverified,
      "turnout_state_manifests" => turnout_verified, "unverified_turnout_state_manifests" => turnout_unverified,
      "house_manifests" => manifests(result.fetch("house_units"), "race_key"),
      "house_totals_current_lines" => current_totals,
      "provenance" => provenance,
      "revision" => Digest::SHA256.hexdigest(revisions.join(":")))
    result
  rescue JSON::ParserError, CSV::MalformedCSVError, KeyError, TypeError, Errno::ENOENT => error
    raise Invalid, "invalid historical baseline: #{error.message}"
  end

  private
    def verify_file!(path, expected)
      unless expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(path).hexdigest == expected
        raise Invalid, "historical checksum mismatch: #{path.basename}"
      end
    end

    def integer(value)
      raise Invalid, "invalid historical vote count: #{value.inspect}" unless value.is_a?(String) && value.match?(/\A\d+\z/)
      value.to_i
    end

    def read_units(filename, year, kind)
      table = CSV.read(@directory.join(filename), headers: true)
      raise Invalid, "historical columns mismatch: #{filename}" unless table.headers == COLUMNS
      rows = table.map do |row|
        state, fips, race, name = row.values_at("state", "county_fips", "race_key", "county_name")
        unless STATE_FIPS.key?(state) && fips&.match?(/\A\d{5}\z/) && fips.start_with?(STATE_FIPS.fetch(state))
          raise Invalid, "invalid historical state/county FIPS"
        end
        unless valid_race?(race, state) && ((kind == "units") == race.end_with?("-P")) && (kind != "house_units" || !race.end_with?("-S"))
          raise Invalid, "invalid historical race identity: #{race}"
        end
        raise Invalid, "historical geography year mismatch" unless integer(row["geography_year"]) == year
        raise Invalid, "missing historical county name" unless name.is_a?(String) && !name.strip.empty?
        unit_key = ElectionNight::Sources::Base.new(state: state).send(:unit_key, name)
        votes = %w[dem_votes rep_votes other_votes total_votes].to_h { |field| [ field, integer(row[field]) ] }
        unless votes.fetch("total_votes").positive? && votes.values_at("dem_votes", "rep_votes", "other_votes").sum == votes.fetch("total_votes")
          raise Invalid, "historical candidate counts do not equal total"
        end
        ids = row["source_ids"].to_s.split("|")
        raise Invalid, "unknown historical source" if ids.empty? || (ids - @known_source_ids).any?
        { "race_key" => race, "state" => state, "county_fips" => fips, "unit_key" => unit_key,
          "county_name" => name, "geography_year" => year, "geography_level" => "county",
          "district_portion" => !race.end_with?("-P", "-S"), "source_ids" => ids,
          "source_url" => ids.include?("tonmcg:president:2024") ?
            "https://github.com/tonmcg/US_County_Level_Election_Results_08-24" : "https://doi.org/10.5281/zenodo.22976553",
          "quality_flags" => row["quality_flags"].to_s.split("|") }.merge(votes)
      end
      [ "unit_key", "county_fips" ].each do |field|
        identities = rows.map { |row| row.values_at("race_key", field) }
        raise Invalid, "duplicate historical race/county #{field}" unless identities.size == identities.uniq.size
      end
      rows
    end

    def valid_race?(race, state)
      return true if [ "#{state}-P", "#{state}-S" ].include?(race)
      return race == "#{state}-AL" if AT_LARGE.include?(state)
      race&.match?(/\A#{state}-\d{2}\z/) && race.split("-").last.to_i.between?(1, SEATS.fetch(state))
    end

    def manifests(rows, key)
      rows.group_by { |row| row.fetch(key) }.transform_values { |group| group.map { |row| row.fetch("unit_key") }.sort }
    end

    def verified_state_manifests(rows)
      roster = JSON.parse(@directory.join("county_roster.json").read)
      verified, unverified = {}, {}
      rows.group_by { |row| row.fetch("state") }.each do |state, group|
        old_fips = roster.fetch("2020").fetch(state).map { |row| row.fetch("county_fips") }.sort
        new_fips = roster.fetch("2024").fetch(state).map { |row| row.fetch("county_fips") }.sort
        # Connecticut's eight legacy counties remain an explicitly historical
        # reporting geography; its nine planning regions cannot match these.
        expected = state == "CT" ? old_fips : new_fips
        expected -= [ "15005" ] if state == "HI" # Official Maui reporting consolidation.
        actual = group.map { |row| row.fetch("county_fips") }.sort
        keys = group.map { |row| row.fetch("unit_key") }.sort
        if actual == expected && (old_fips == new_fips || state == "CT")
          verified[state] = keys
        else
          unverified[state] = { "unit_keys" => keys, "missing_county_fips" => expected - actual,
            "unexpected_county_fips" => actual - expected, "reason" => "Historical state units do not match independently verified county roster" }
        end
      end
      [ verified, unverified ]
    end

    def current_line_totals
      @current_lines_provenance = nil
      return [] unless @current_lines_directory
      # The existing catalog is JSON-compatible YAML. Its pinned data checksum
      # is verified here without changing or depending on Forecast model logic.
      manifest_body = @current_lines_directory.join("manifest.yml").read
      manifest = JSON.parse(manifest_body)
      raise Invalid, "wrong current-line cycle" unless manifest.fetch("cycle") == 2026
      source = manifest.fetch("sources").fetch("presidential_2024.csv")
      path = @current_lines_directory.join("presidential_2024.csv")
      verify_file!(path, source.fetch("sha256"))
      @current_lines_provenance = { "manifest_sha256" => Digest::SHA256.hexdigest(manifest_body),
        "data_file" => "house_baselines/2026/presidential_2024.csv", "data_sha256" => source.fetch("sha256"),
        "source_revision" => manifest.fetch("version"), "source_url" => source.fetch("url"),
        "publisher" => source.fetch("publisher"), "geography_year" => 2026,
        "historical_election_date" => "2024-11-05", "aggregate_only" => true }
      rows = CSV.read(path, headers: true).map do |row|
        state, district = row.values_at("state", "district")
        district = integer(district)
        raise Invalid, "invalid current-line district" unless SEATS.key?(state) && district.between?(1, SEATS.fetch(state))
        key = AT_LARGE.include?(state) ? "#{state}-AL" : "#{state}-#{format('%02d', district)}"
        dem, rep, total = row.values_at("dem_votes", "rep_votes", "total_votes").map { |value| integer(value) }
        raise Invalid, "invalid current-line totals" unless total.positive? && dem + rep <= total
        { "race_key" => key, "state" => state, "unit_key" => "CONTEST", "geography_level" => "contest",
          "aggregate_only" => true, "geography_year" => 2026, "historical_election_date" => "2024-11-05",
          "dem_votes" => dem, "rep_votes" => rep, "other_votes" => total - dem - rep, "total_votes" => total,
          "source_ids" => [ "downballot:president:2024:current_lines" ], "source_url" => source.fetch("url"),
          "source_basis" => "2024 presidential raw votes reaggregated to 2026 congressional boundaries",
          "source_revision" => manifest.fetch("version") }
      end
      expected = SEATS.flat_map { |state, n| (1..n).map { |district| AT_LARGE.include?(state) ? "#{state}-AL" : "#{state}-#{format('%02d', district)}" } }.sort
      raise Invalid, "incomplete current-line House totals" unless rows.map { |row| row.fetch("race_key") }.sort == expected
      rows
    end
end
