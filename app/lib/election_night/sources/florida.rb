require "csv"

class ElectionNight::Sources::Florida < ElectionNight::Sources::Base
  COLUMNS = %w[ElectionDate PartyCode RaceCode RaceName CountyCode CountyName Juris1num CanNameLast CanNameFirst CanNameMiddle CanVotes].freeze

  def parse(body)
    parse_rows(body)
  end

  def parse_baselines(body)
    historical = self.class.new(state: state, election_date: "2024-11-05")
    result = historical.send(:parse_rows, body, presidential: true)
    result["house_units"] = historical.parse(body)["units"].reject { |unit| unit["race_key"].end_with?("-S") }
    result
  end

  private
    def parse_rows(body, presidential: false)
      raise InvalidData, "Florida-only source" unless state == "FL"
      rows = CSV.parse(body, headers: true, col_sep: "\t", quote_char: nil)
      raise InvalidData, "missing Florida columns" unless (COLUMNS - Array(rows.headers)).empty?
      units, seen, county_names, candidate_counties = {}, {}, {}, {}
      rows.each do |row|
        validate_date!(Date.strptime(row.fetch("ElectionDate"), "%m/%d/%Y").iso8601)
        code = row.fetch("RaceCode")
        next unless presidential ? code == "PRE" : %w[USS USR].include?(code)
        key = race_key(row.fetch("RaceName"), presidential: presidential)
        raise InvalidData, "unexpected federal contest name" unless key
        if code == "USR"
          district = count(row.fetch("Juris1num").strip)
          raise InvalidData, "conflicting congressional district" unless key == "FL-#{format('%02d', district)}"
        end
        county = row.fetch("CountyCode")
        raise InvalidData, "missing county code" if county.to_s.strip.empty?
        name = unit_key(row.fetch("CountyName"))
        raise InvalidData, "conflicting county names" if county_names.key?(county) && county_names[county] != name
        county_names[county] = name
        candidate = %w[CanNameLast CanNameFirst CanNameMiddle PartyCode].map { |column| row.fetch(column).to_s.strip }
        raise InvalidData, "missing candidate name" if candidate.first.to_s.empty?
        identity = [ key, county, candidate ]
        raise InvalidData, "duplicate candidate/county count" if seen[identity]
        seen[identity] = true
        (candidate_counties[key] ||= {})[candidate] ||= []
        candidate_counties[key][candidate] << county
        unit = (units[[ key, county ]] ||= empty_unit(key, name))
        add_votes(unit, row.fetch("PartyCode"), row.fetch("CanVotes"))
      end
      candidate_counties.each_value do |candidates|
        raise InvalidData, "incomplete candidate county coverage" unless candidates.values.map(&:sort).uniq.length == 1
      end
      # PrecinctsReporting is not an estimated vote fraction or a finality flag.
      # This file contains no publication timestamp; HTTP retrieval time is
      # retained separately by the collector rather than invented here.
      output(units.values)
    rescue CSV::MalformedCSVError, Date::Error, KeyError, TypeError => error
      raise InvalidData, "invalid Florida results: #{error.message}"
    end
end
