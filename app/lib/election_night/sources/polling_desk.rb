require "csv"
require_relative "civic_api"

# Last-resort raw totals, never geographic evidence. The publisher's canonical
# 2026 catalog is the November general election; the CSV has no date column.
# Keep that limitation visible rather than manufacturing a source date field.
class ElectionNight::Sources::PollingDesk < ElectionNight::Sources::Base
  COLUMNS = %w[cycle office state district race_key candidate party votes results_updated_utc source].freeze
  AT_LARGE = ElectionNight::Sources::CivicApi::AT_LARGE
  HOUSE_SEATS = ElectionNight::Sources::CivicApi::HOUSE_SEATS
  # The 33 Class 2 seats plus Florida and Ohio specials, as pinned in
  # db/seed_data/senate_2026.yml. Cardinality alone cannot identify this map.
  SENATE_STATES = %w[AK AL AR CO DE FL GA IA ID IL KS KY LA MA ME MI MN MS MT NC NE NH NJ NM OH OK OR RI SC SD TN TX VA WV WY].freeze
  EXPECTED_RACES = (HOUSE_SEATS.flat_map do |area, seats|
    AT_LARGE.include?(area) ? [ "#{area}-AL" ] : (1..seats).map { |district| "#{area}-#{format('%02d', district)}" }
  end + SENATE_STATES.map { |area| "#{area}-S" }).sort.freeze

  def parse(body)
    raise InvalidData, "national 2026 general catalog required" unless state == "US" && election_date == "2026-11-03"
    rows = CSV.parse(body.dup.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF"), headers: true)
    raise InvalidData, "missing CSV columns" unless (COLUMNS - Array(rows.headers)).empty?
    units, seen, times = {}, {}, []
    rows.each do |row|
      next unless %w[house senate].include?(row["office"])
      raise InvalidData, "wrong election cycle" unless row["cycle"] == "2026"
      area = row.fetch("state")
      raise InvalidData, "invalid state" unless HOUSE_SEATS.key?(area)
      key = if row["office"] == "senate"
        raise InvalidData, "unexpected Senate contest" unless SENATE_STATES.include?(area)
        raise InvalidData, "unexpected Senate identifier" unless row["race_key"] == "2026/senate/#{area.downcase}" && row["district"].to_s.empty?
        "#{area}-S"
      else
        district = row.fetch("district")
        raise InvalidData, "invalid congressional district" unless district&.match?(/\A\d{1,2}\z/) && district.to_i.between?(1, HOUSE_SEATS.fetch(area))
        expected = "2026/house/#{area.downcase}-#{format('%02d', district.to_i)}"
        raise InvalidData, "inconsistent congressional identifier" unless row["race_key"] == expected
        raise InvalidData, "invalid at-large district" if AT_LARGE.include?(area) && district.to_i != 1
        AT_LARGE.include?(area) ? "#{area}-AL" : "#{area}-#{format('%02d', district.to_i)}"
      end
      candidate = row.fetch("candidate").to_s.strip
      raise InvalidData, "missing or duplicate candidate" if candidate.empty? || seen[[ key, candidate.downcase ]]
      seen[[ key, candidate.downcase ]] = true
      raise InvalidData, "unexpected upstream attribution" unless row["source"] == "civicAPI (civicapi.org)"
      raw_time = row.fetch("results_updated_utc")
      raise InvalidData, "invalid UTC update time" unless raw_time.match?(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/)
      published = timestamp(raw_time.tr(" ", "T") + "Z")
      times << published
      unit = (units[key] ||= empty_unit(key, "CONTEST TOTAL").merge(
        "aggregate_only" => true, "geography_level" => "contest", "published_at" => published))
      unit["published_at"] = [ unit["published_at"], published ].min
      add_votes(unit, row.fetch("party"), row.fetch("votes"))
      # winner, percent_reporting, percent, seats and chamber-control rows
      # never enter the normalized data or our model.
    end
    raise InvalidData, "incorrect national catalog" unless units.keys.sort == EXPECTED_RACES
    output(units.values, published_at: times.max).merge(
      "election_date_basis" => "Publisher's canonical 2026 general-election catalog; CSV has no explicit election-date or test-data field.",
      "upstream_url" => "https://civicapi.org/", "aggregate_only" => true
    )
  rescue CSV::MalformedCSVError, KeyError, TypeError => error
    raise InvalidData, "invalid Polling Desk CSV: #{error.message}"
  end
end
