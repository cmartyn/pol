# Official county summary files. The collector resolves current_ver.txt and
# fetches summary + election settings from the same immutable version.
class ElectionNight::Sources::ClarityCounty < ElectionNight::Sources::Base
  def parse(body, metadata:)
    contests = body.is_a?(Array) ? body : JSON.parse(body)
    info = document(metadata)
    details = info.fetch("settings").fetch("electiondetails")
    validate_date!(Date.strptime(details.fetch("electiondate"), "%m/%d/%Y").iso8601)
    raise InvalidData, "county state mismatch" unless info.fetch("parententityname").upcase == state
    raise InvalidData, "expected county results" unless details["isstate"] == false
    raise InvalidData, "test county results" unless [ "false", "0" ].include?(details.fetch("istestmode").to_s) && details.fetch("showtestdatawatermark").to_s == "0"
    raise InvalidData, "test election name" if details.fetch("internalname").match?(/\btest\b/i)
    raise InvalidData, "expected contest array" unless contests.is_a?(Array)
    units = contests.filter_map do |contest|
      name = contest.fetch("C")
      next unless contest.fetch("CAT").upcase == "FEDERAL" || name.match?(/\bCongress|\bCD\s+\d/i)
      key = federal_key(name)
      next unless key
      raise InvalidData, "unsupported ranked-choice summary" if contest["IsRCV"] == true
      names, parties, votes = contest.values_at("CH", "P", "V")
      unless [ names, parties, votes ].all? { |values| values.is_a?(Array) } && names.any? && names.size == parties.size && names.size == votes.size
        raise InvalidData, "candidate arrays do not align"
      end
      raise InvalidData, "duplicate candidate" unless names.uniq.size == names.size
      unit = empty_unit(key, info.fetch("entityname"))
      parties.zip(votes).each { |party, vote| add_votes(unit, party, vote) }
      raise InvalidData, "candidate sum differs from contest total" unless count(contest.fetch("TV")) == unit["total_votes"]
      unit
    end
    # The publisher's timezone abbreviations vary; do not invent an offset.
    output(units).merge("source_local_timestamp" => info["websiteupdatedat"])
  rescue JSON::ParserError, Date::Error, KeyError, TypeError, NoMethodError => error
    raise InvalidData, "invalid Clarity county schema: #{error.message}"
  end

  private
    def federal_key(name)
      return race_key(name) if name.match?(/(?:United States|U\.?\s?S\.?) Senate/i)
      match = name.match(/\AHouse of Representatives\s*-\s*CD\s*(\d+)\z/i) ||
        name.match(/\A(?:House of Representatives|Member of (?:the )?House of Representatives|US House|U\.S\. House)(?:\s*[-–,])?\s*(\d+)(?:st|nd|rd|th)?\s*(?:Cong|District)/i) ||
        name.match(/\A(?:House of Representatives|Representative in Congress).*?(\d+)(?:st|nd|rd|th)?\s*(?:Congressional )?District/i)
      return "#{state}-#{format('%02d', match[1].to_i)}" if match
      race_key(name)
    end
end
