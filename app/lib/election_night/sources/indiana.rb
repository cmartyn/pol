class ElectionNight::Sources::Indiana < ElectionNight::Sources::Base
  # The official client reads settings.json first and substitutes VersionType
  # into OffCatC_1005_{version}.json. Never hard-code the alternating A/B file.
  def parse(body, metadata:)
    raise InvalidData, "Indiana-only source" unless state == "IN"
    settings = document(metadata).fetch("Root")
    validate_date!(Date.strptime(settings.fetch("CurrentElection"), "%m/%d/%Y").iso8601)
    raise InvalidData, "wrong Indiana election/state" unless settings["ElectionType"] == "G" && settings["StateFP"] == "18"
    raise InvalidData, "unexpected Indiana data version" unless %w[A B].include?(settings["VersionType"])
    raise InvalidData, "Indiana test data" if settings["IsTest"].to_s.match?(/\A(?:true|1|T)\z/i)

    data = document(body).fetch("Root")
    category = data.fetch("OfficeCategory")
    raise InvalidData, "not the federal House export" unless category["OFFICECATEGORYID"] == "1005" && category["OFFICE_CATEGORY_NAME"] == "US Representative"
    published = local_timestamp(data.fetch("WriteTime"))
    settings_time = local_timestamp(settings.fetch("WriteTime"))
    raise InvalidData, "results predate current election" if published.to_date < Date.iso8601(election_date)
    raise InvalidData, "results/settings generation mismatch" if published > settings_time + 300

    summaries = list(data.fetch("StatewideSummary").fetch("Race")).each_with_object({}) do |race, lookup|
      office = race.fetch("OFFICEID")
      raise InvalidData, "duplicate statewide summary contest" if lookup.key?(office)
      lookup[office] = candidate_counts(race, party_field: "PARTY", votes_field: "TOTAL")
    end
    units, districts, offices, fips_names = [], [], [], {}
    list(category.fetch("Regions").fetch("Region")).each do |region|
      raise InvalidData, "unexpected Indiana region" unless region["MAP_JURISDICTION_TYPE"] == "District"
      district = count(region.fetch("MAP_JURISDICTION_NAME"))
      raise InvalidData, "duplicate or invalid Indiana district" unless (1..9).cover?(district) && !districts.include?(district)
      districts << district
      key = "IN-#{format('%02d', district)}"
      summary = region.fetch("RegionSummary").fetch("Race")
      raise InvalidData, "unexpected district identity" unless summary["SubSortOrder"] == "United States Representative, (#{district}) District" && summary["NumofSeats"] == "1"
      office = summary.fetch("OFFICEID")
      raise InvalidData, "duplicate district office" if offices.include?(office)
      offices << office
      expected = candidate_counts(summary, party_field: "PARTY", votes_field: "TOTAL")
      raise InvalidData, "district/state summary mismatch" unless summaries.fetch(office) == expected
      accumulated = expected.transform_values { 0 }
      county_fips = []
      list(region.fetch("Races").fetch("Race")).each do |race|
        raise InvalidData, "county/district contest mismatch" unless race["OFFICEID"] == office && race["SubSortOrder"] == summary["SubSortOrder"] && race["NumofSeats"] == "1"
        county = race.fetch("Jurisdiction")
        fips = county.fetch("FIPS")
        raise InvalidData, "invalid or duplicate county FIPS" unless fips.match?(/\A18\d{3}\z/) && !county_fips.include?(fips) && county["JURISDICTION_TYPE"] == "Locality"
        county_fips << fips
        name = unit_key(county.fetch("JURISDICTION_NAME"))
        raise InvalidData, "inconsistent county name" if fips_names.key?(fips) && fips_names[fips] != name
        fips_names[fips] = name
        counts = candidate_counts(race, party_field: "PARTY_ABBREV", votes_field: "TOTAL_VOTES")
        raise InvalidData, "incomplete county candidate scaffold" unless counts.keys.sort == expected.keys.sort
        unit = empty_unit(key, name)
        counts.each do |identity, votes|
          accumulated[identity] += votes
          add_votes(unit, identity.last, votes)
        end
        units << unit
      end
      raise InvalidData, "missing county results or inconsistent candidate totals" unless county_fips.any? && accumulated == expected
    end
    raise InvalidData, "incomplete Indiana House scaffold" unless districts.sort == (1..9).to_a && summaries.keys.sort == offices.sort
    output(units, published_at: published.utc.iso8601).merge(
      "coverage_note" => "Official county portions for all nine House districts; district summaries are cross-checks, not additional votes."
    )
  rescue KeyError, TypeError, NoMethodError, Date::Error, ArgumentError => error
    raise InvalidData, "invalid Indiana results: #{error.message}"
  end

  private
    def list(value)
      return value if value.is_a?(Array) && value.any?
      return [ value ] if value.is_a?(Hash)
      raise InvalidData, "missing Indiana collection"
    end

    def candidate_counts(race, party_field:, votes_field:)
      list(race.fetch("Candidates").fetch("Candidate")).each_with_object({}) do |candidate, counts|
        name = candidate.fetch("NAME_ON_BALLOT").to_s.strip
        party = candidate.fetch(party_field).to_s.strip
        identity = [ name, party ]
        raise InvalidData, "missing or duplicate candidate" if name.empty? || party.empty? || counts.key?(identity)
        counts[identity] = count(candidate.fetch(votes_field))
      end
    end

    def local_timestamp(value)
      # The state export lacks an offset. Indianapolis is EST on Nov. 3, 2026.
      # Require a local ISO timestamp rather than silently honoring an injected
      # offset or relying on the host's timezone.
      raise InvalidData, "invalid Indiana local timestamp" unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?\z/)
      Time.iso8601("#{value}-05:00")
    end
end
