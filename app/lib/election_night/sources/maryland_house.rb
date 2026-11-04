require "nokogiri"

# State-published district totals. NR is missing data, never a zero vote.
class ElectionNight::Sources::MarylandHouse < ElectionNight::Sources::Base
  def parse(body)
    raise InvalidData, "Maryland House source requires MD" unless state == "MD" && election_date == "2026-11-03"
    html = Nokogiri::HTML(body)
    title = html.at_css("h1")&.text.to_s.strip
    unless title.match?(/\A(?:Unofficial|Official) 2026 Gubernatorial General Election Results for Representative in Congress\z/)
      raise InvalidData, "wrong Maryland election or office"
    end
    unavailable = {}
    seen = []
    units = html.css("h3").filter_map do |heading|
      match = heading.text.strip.match(/\ADistrict ([1-8])\z/)
      next unless match
      key = "MD-#{format('%02d', match[1].to_i)}"
      raise InvalidData, "duplicate district" if seen.include?(key)
      seen << key
      table = heading.xpath("following-sibling::div[1]/table").first
      raise InvalidData, "missing district table" unless table
      headers = table.css("thead th").map { |cell| cell.text.strip }
      required = [ "Name", "Party", "Early Voting", "Election Day", "Mail-In Ballot", "Provisional", "Total", "Percentage" ]
      raise InvalidData, "changed Maryland columns" unless headers == required
      rows = table.css("tbody tr").map { |row| row.css("td").map { |cell| cell.text.strip } }
      raise InvalidData, "missing candidate rows" unless rows.size >= 3 && rows.all? { |row| row.size == headers.size }
      totals = rows.select { |row| row[0] == "Totals" }
      raise InvalidData, "duplicate contest total" if totals.size > 1
      candidates = rows.reject { |row| row[0] == "Totals" }
      raise InvalidData, "duplicate candidate" unless candidates.map(&:first).uniq.size == candidates.size
      if rows.any? { |row| row[6] == "NR" }
        unavailable[key] = "State reports NR (not reported); no vote total substituted"
        next
      end
      unit = empty_unit(key, "DISTRICT #{match[1]}").merge("aggregate_only" => true, "geography_level" => "contest")
      candidates.each { |row| add_votes(unit, row[1], numeric_total(row[6])) }
      if totals.any? && numeric_total(totals.first[6]) != unit["total_votes"]
        raise InvalidData, "candidate sum differs from contest total"
      end
      unit
    end
    raise InvalidData, "incomplete Maryland district scaffold" unless seen.sort == (1..8).map { |n| "MD-#{format('%02d', n)}" }
    result = units.empty? ? { "election_date" => election_date, "published_at" => nil, "test" => false, "units" => [] } : output(units)
    result.merge("unavailable_races" => unavailable)
  end

  private
    def numeric_total(value)
      raise InvalidData, "invalid Maryland vote count" unless value.match?(/\A(?:\d+|\d{1,3}(?:,\d{3})+)\z/)
      count(value.delete(","))
    end
end
