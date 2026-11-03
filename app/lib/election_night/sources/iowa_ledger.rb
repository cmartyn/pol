# Alternative publisher of official raw totals. This adapter deliberately
# ignores leader, call, percent-counted and any presentation-derived fields.
class ElectionNight::Sources::IowaLedger < ElectionNight::Sources::Base
  def parse(body)
    raise InvalidData, "Iowa Ledger is an Iowa-only source" unless state == "IA"
    data = document(body)
    validate_date!(data.fetch("election").fetch("date"))
    raise InvalidData, "unexpected election" unless data.dig("election", "key") == "2026-general"
    units = data.fetch("races").filter_map do |id, race|
      if id == "us-senate"
        key, geography = "IA-S", "STATEWIDE"
      elsif (match = id.match(/\Aus-house-(\d+)\z/))
        district = match[1].to_i
        raise InvalidData, "invalid Iowa district" unless (1..4).cover?(district)
        key, geography = "IA-#{format('%02d', district)}", "DISTRICT #{format('%02d', district)}"
      else
        next
      end
      unit = empty_unit(key, geography)
      race.fetch("candidates").each { |candidate| add_votes(unit, candidate["party"], candidate.fetch("votes")) }
      raise InvalidData, "candidate sum differs from contest total" unless count(race.fetch("votes")) == unit["total_votes"]
      # County reporting counts are not the share of votes counted.
      unit.merge("geography_level" => "contest", "aggregate_only" => true)
    end
    expected = [ "IA-S", "IA-01", "IA-02", "IA-03", "IA-04" ]
    raise InvalidData, "incomplete federal contest scaffold" unless units.map { |u| u["race_key"] }.sort == expected.sort
    output(units, published_at: timestamp(data.fetch("sosUpdatedAt"))).merge(
      "upstream_url" => data.fetch("sourceUrl"), "publisher_fetched_at" => timestamp(data.fetch("fetchedAt")),
      "coverage_note" => "Alternative publisher of official totals; county-level breakdown unavailable."
    )
  rescue KeyError, TypeError, NoMethodError => error
    raise InvalidData, "invalid Iowa Ledger schema: #{error.message}"
  end
end
