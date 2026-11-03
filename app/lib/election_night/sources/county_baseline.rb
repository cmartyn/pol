require "csv"

# Raw historical counts, not probabilities. Used only where a verified
# official historical export is not yet wired. The fetched file and hash are
# frozen by the collector so changes to the public compilation are auditable.
class ElectionNight::Sources::CountyBaseline < ElectionNight::Sources::Base
  STATE_FIPS = { "AZ" => "04", "OH" => "39", "TX" => "48" }.freeze
  COLUMNS = %w[county_fips county_name votes_gop votes_dem total_votes].freeze

  def parse_baselines(body)
    prefix = STATE_FIPS.fetch(state) { raise InvalidData, "unsupported historical state" }
    rows = CSV.parse(body, headers: true)
    raise InvalidData, "missing historical columns" unless (COLUMNS - Array(rows.headers)).empty?
    units = rows.filter_map do |row|
      next unless row["county_fips"].to_s.start_with?(prefix)
      raise InvalidData, "invalid county FIPS" unless row["county_fips"].match?(/\A\d{5}\z/)
      unit = empty_unit("#{state}-P", row.fetch("county_name"))
      add_votes(unit, "dem", row.fetch("votes_dem"))
      add_votes(unit, "rep", row.fetch("votes_gop"))
      total = count(row.fetch("total_votes"))
      raise InvalidData, "historical candidate sum exceeds total" if total < unit["total_votes"]
      add_votes(unit, "other", total - unit["total_votes"])
      unit
    end
    result = output(units)
    result["election_date"] = "2024-11-05"
    result["coverage_note"] = "Raw 2024 presidential county compilation; third-party historical data, not a forecast."
    result
  rescue CSV::MalformedCSVError, KeyError, TypeError => error
    raise InvalidData, "invalid historical county data: #{error.message}"
  end
end
