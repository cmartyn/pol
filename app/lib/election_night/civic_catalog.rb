require "json"
require "digest"
require "pathname"

# Pinned discovery catalog, not election results. Every endpoint must still pass
# the full-race adapter before its candidate counts can be used.
class ElectionNight::CivicCatalog
  DEFAULT_PATH = Pathname.new(__dir__).join("../../../config/election_night_civic_races.json").freeze
  SENATE_STATES = %w[AK AL AR CO DE FL GA IA ID IL KS KY LA MA ME MI MN MS MT NC NE NH NJ NM OH OK OR RI SC SD TN TX VA WV WY].freeze
  attr_reader :data, :sha256

  def initialize(path: DEFAULT_PATH)
    body = File.binread(path)
    @sha256 = Digest::SHA256.hexdigest(body)
    @data = JSON.parse(body)
    validate!
  end

  def races = data.fetch("races")

  def sources(minimum_interval: 180, priority: 0)
    races.map do |race|
      {
        "id" => "civic_#{race.fetch('race_key').downcase.tr('-', '_')}",
        "state" => race.fetch("state"), "adapter" => "civic_api",
        "label" => "CivicAPI raw results — #{race.fetch('race_key')}",
        "url" => race.fetch("url"), "expected_races" => [ race.fetch("race_key") ],
        "source_kind" => "secondary", "source_role" => "primary", "upstream_url" => "https://civicapi.org/",
        "minimum_interval" => minimum_interval, "priority" => priority, "enabled" => true,
        "coverage_note" => "Full-race raw counts; county detail requires candidate reconciliation. Zero county sums do not establish a complete manifest. Provider calls, forecasts and modeled vote remaining are excluded."
      }
    end
  end

  private
    def validate!
      raise ArgumentError, "Wrong Civic catalog election" unless data.fetch("election_date") == "2026-11-03"
      raise ArgumentError, "Civic catalog must contain 470 races" unless races.is_a?(Array) && races.size == 470
      keys = races.map { |race| race.fetch("race_key") }
      ids = races.map { |race| race.fetch("id") }
      raise ArgumentError, "Duplicate Civic race keys or endpoint IDs" unless keys.uniq.size == 470 && ids.uniq.size == 470
      expected_house = ElectionNight::Sources::CivicApi::HOUSE_SEATS.flat_map do |state, count|
        count == 1 ? [ "#{state}-AL" ] : (1..count).map { |district| "#{state}-#{format('%02d', district)}" }
      end
      actual_house = races.select { |r| r["chamber"] == "house" }.map { |r| r["race_key"] }
      raise ArgumentError, "Incomplete congressional catalog" unless actual_house.sort == expected_house.sort
      senate = races.select { |r| r["chamber"] == "senate" }
      raise ArgumentError, "Incomplete Senate catalog" unless senate.map { |r| r["race_key"] }.sort == SENATE_STATES.map { |state| "#{state}-S" }.sort
      races.each do |race|
        state, id, key = race.values_at("state", "id", "race_key")
        valid = ElectionNight::Sources::CivicApi::STATES.include?(state) && id.is_a?(Integer) && id.positive?
        valid &&= key.start_with?("#{state}-") && race["url"] == "https://civicapi.org/api/v2/race/#{id}"
        valid &&= race["chamber"] == "house" || (race["chamber"] == "senate" && key == "#{state}-S")
        raise ArgumentError, "Invalid Civic catalog race" unless valid
      end
    end
end
