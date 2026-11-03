# Public full-race endpoint only. Search and national summary responses can
# truncate or retain older candidate lists, and are not accepted here.
class ElectionNight::Sources::CivicApi < ElectionNight::Sources::Base
  STATES = %w[AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY].freeze
  AT_LARGE = %w[AK DE ND SD VT WY].freeze
  HOUSE_SEATS = STATES.zip([ 7, 1, 9, 4, 52, 8, 5, 1, 28, 14, 2, 2, 17, 9, 4, 4, 6, 6, 2, 8, 9, 13, 8, 4, 8, 2, 3, 4, 2, 12, 3, 26, 14, 1, 15, 5, 6, 17, 2, 7, 1, 9, 38, 4, 1, 11, 10, 2, 8, 1 ]).to_h.freeze

  def parse(body)
    data = document(body)
    raise InvalidData, "expected United States race" unless data.fetch("country") == "US"
    raise InvalidData, "race state mismatch" unless STATES.include?(state) && data.fetch("province") == state
    raise InvalidData, "expected general election" unless data.fetch("election_scope") == "General"
    raise InvalidData, "test flag must explicitly be false" unless data.fetch("test_data") == false
    raise InvalidData, "unexpected municipality" unless data.fetch("municipality").nil?
    validate_date!(data.fetch("election_date"))
    key = federal_race(data)
    candidates = candidate_counts(data.fetch("candidates"), require_ids: true)
    aggregate = result_unit(key, key.end_with?("-S") ? "STATEWIDE" : "DISTRICT #{key.split('-').last}", candidates)
      .merge("aggregate_only" => true, "geography_level" => "contest")
    regions = data.fetch("region_results")
    raise InvalidData, "expected region results object" unless regions.is_a?(Hash)

    # The response can hold a statewide summary, counties, towns, precincts,
    # and other overlapping subdivisions. Only county equivalents enter units.
    regional = regions.values.select { |region| region.is_a?(Hash) && [ "County", "Borough", "Parish", "Independent City" ].include?(region["type"]) }
    county_counts = regional.map { |region| candidate_counts(region.fetch("candidates")) }
    same_candidates = county_counts.all? { |counts| counts.keys.sort == candidates.keys.sort }
    matching_sums = same_candidates && regional.any? && candidates.all? do |candidate, votes|
      county_counts.sum { |counts| counts.fetch(candidate) } == votes
    end
    units = regional.zip(county_counts).map do |region, counts|
      name = region.fetch("name")
      name = "#{name} City" if region["type"] == "Independent City" && !name.end_with?(" City")
      unit = result_unit(key, name, counts).merge("geography_level" => "county")
      if region["fips"]
        raise InvalidData, "invalid county FIPS" unless region["fips"].is_a?(String) && region["fips"].match?(/\A\d{5}\z/)
        unit["county_fips"] = region["fips"]
      end
      unit
    end
    if units.map { |unit| unit["unit_key"] }.uniq.size != units.size
      raise InvalidData, "duplicate county geography"
    end
    fips = units.filter_map { |unit| unit["county_fips"] }
    raise InvalidData, "duplicate county FIPS" unless fips.uniq.size == fips.size

    result = { "election_date" => election_date, "published_at" => timestamp(data.fetch("last_updated")),
      "test" => false, "source_scope" => "race", "units" => matching_sums ? units.sort_by { |unit| unit["unit_key"] } : [],
      "aggregate_units" => [ aggregate ], "county_totals_match_aggregate" => matching_sums }
    unless matching_sums
      result["county_detail_reason"] = if regional.empty?
        "No county-level breakdown published; contest total retained"
      elsif !same_candidates
        "County candidate lists differ from the full race; contest total retained"
      else
        "County counts do not reconcile with the full race; contest total retained"
      end
    end
    result
  rescue KeyError, TypeError, NoMethodError => error
    raise InvalidData, "invalid Civic API full-race schema: #{error.message}"
  end

  private
    def federal_race(data)
      case data.fetch("election_type")
      when "US Senate"
        raise InvalidData, "unexpected Senate district" unless data.fetch("district").nil?
        "#{state}-S"
      when "House of Representatives"
        district = data.fetch("district")
        valid_number = district.is_a?(String) && district.match?(/\A#{state}-(?:0[1-9]|[1-4]\d|5[0-2])\z/)
        valid_at_large = AT_LARGE.include?(state) && district == "#{state}-AL"
        raise InvalidData, "invalid congressional district" unless valid_number || valid_at_large
        raise InvalidData, "expected at-large district" if AT_LARGE.include?(state) && !valid_at_large
        raise InvalidData, "district exceeds state delegation" if valid_number && district.split("-").last.to_i > HOUSE_SEATS.fetch(state)
        district
      else
        raise InvalidData, "unsupported federal office"
      end
    end

    def candidate_counts(rows, require_ids: false)
      raise InvalidData, "missing candidate list" unless rows.is_a?(Array) && rows.any?
      if require_ids
        ids = rows.map { |candidate| candidate.fetch("candidate_id") }
        raise InvalidData, "invalid or duplicate candidate ID" unless ids.all? { |id| id.is_a?(Integer) && id.positive? } && ids.uniq.size == ids.size
      end
      rows.each_with_object({}) do |candidate, counts|
        name, party = candidate.values_at("name", "party")
        unless name.is_a?(String) && !name.strip.empty? && party.is_a?(String) && !party.strip.empty?
          raise InvalidData, "missing candidate name or party"
        end
        key = [ name.strip.gsub(/\s+/, " ").downcase, party.strip.downcase ]
        raise InvalidData, "duplicate candidate identity" if counts.key?(key)
        counts[key] = count(candidate.fetch("votes"))
      end
    end

    def result_unit(race, name, candidates)
      unit = empty_unit(race, name)
      candidates.each { |(_name, party), votes| add_votes(unit, party, votes) }
      unit
    end
end
