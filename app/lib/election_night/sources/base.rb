require "date"
require "json"
require "time"

class ElectionNight::Sources::Base
  InvalidData = Class.new(StandardError)

  def initialize(state:, election_date: "2026-11-03")
    @state = state.to_s.upcase
    @election_date = Date.iso8601(election_date.to_s).iso8601
    raise ArgumentError, "invalid state" unless @state.match?(/\A[A-Z]{2}\z/)
  end

  private
    attr_reader :state, :election_date

    def document(body)
      body.is_a?(Hash) ? body : JSON.parse(body)
    rescue JSON::ParserError => error
      raise InvalidData, "invalid JSON: #{error.message}"
    end

    def validate_date!(actual)
      actual = Date.iso8601(actual.to_s).iso8601
      raise InvalidData, "wrong election date #{actual}; expected #{election_date}" unless actual == election_date
      actual
    rescue Date::Error
      raise InvalidData, "missing or invalid election date"
    end

    def count(value)
      # Integer(2.9) truncates: explicitly reject floats, blanks and strings
      # containing percent signs instead of silently converting them to votes.
      return value if value.is_a?(Integer) && value >= 0
      return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

      raise InvalidData, "missing, negative or noninteger vote count: #{value.inspect}"
    end

    def unit_key(name)
      key = name.to_s.strip.upcase.gsub(/\s*&\s*/, " AND ").gsub(/\s+/, " ").sub(/ COUNTY\z/, "")
      key = { "DE WITT" => "DEWITT", "LA SALLE" => "LASALLE" }.fetch(key, key) if state == "TX"
      raise InvalidData, "missing reporting unit" if key.empty?
      key
    end

    def party_key(party)
      case party.to_s.strip.downcase
      when "d", "dem", "democrat", "democratic", "democratic party", "democratic-farmer-labor"
        "dem_votes"
      when "r", "rep", "republican", "republican party"
        "rep_votes"
      else
        "other_votes"
      end
    end

    def race_key(name, presidential: false)
      text = name.to_s.upcase.delete(".").gsub(/\bU\s+S\b/, "US").gsub(/\s+/, " ").strip
      if presidential
        return "#{state}-P" if text.match?(/\A(?:US |UNITED STATES )?PRESIDENT\b/)
        return nil
      end
      return "#{state}-S" if text.match?(/\b(?:US|UNITED STATES) SENAT(?:E|OR)\b/)

      federal_house = text.match?(/\b(?:US HOUSE OF REPRESENTATIVES|REPRESENTATIVE (?:IN|TO) CONGRESS|US REPRESENTATIVE DISTRICT)\b/) ||
        (state == "VA" && text.start_with?("MEMBER, HOUSE OF REPRESENTATIVES"))
      return nil unless federal_house

      match = text.match(/DISTRICT(?: NO)?[\s:()#-]*(\d+)/) || text.match(/\b(\d+)(?:ST|ND|RD|TH) DISTRICT\b/)
      return "#{state}-AL" if text.include?("AT LARGE") || text.include?("AT-LARGE")
      raise InvalidData, "cannot identify congressional district: #{name}" unless match
      "#{state}-#{format('%02d', match[1].to_i)}"
    end

    def empty_unit(race, name)
      { "race_key" => race, "unit_key" => unit_key(name), "dem_votes" => 0,
        "rep_votes" => 0, "other_votes" => 0, "total_votes" => 0, "complete" => false }
    end

    def add_votes(unit, party, votes)
      votes = count(votes)
      unit[party_key(party)] += votes
      unit["total_votes"] += votes
    end

    def timestamp(value)
      return nil if value.nil? || value.to_s.empty?
      Time.iso8601(value).utc.iso8601
    rescue ArgumentError
      raise InvalidData, "invalid source timestamp"
    end

    def output(units, published_at: nil)
      raise InvalidData, "no supported federal contests" if units.empty?
      keys = units.map { |unit| [ unit.fetch("race_key"), unit.fetch("unit_key") ] }
      raise InvalidData, "duplicate reporting unit/contest" unless keys.uniq.length == keys.length
      { "election_date" => election_date, "published_at" => published_at,
        "test" => false, "units" => units.sort_by { |unit| [ unit["race_key"], unit["unit_key"] ] } }
    end
end
