class ElectionNight::Sources::California < ElectionNight::Sources::Base
  def parse(body, metadata:)
    raise InvalidData, "California-only source" unless state == "CA"
    # The JSON has reporting times but no election identifier. The official
    # companion index identifies the election and advertises this exact feed.
    heading = metadata.to_s.match(/California ([A-Z][a-z]+ \d{1,2}, \d{4}) Statewide General Election/)
    raise InvalidData, "missing California election metadata" unless heading && metadata.include?("https://media.sos.ca.gov/media/us-rep.json")
    validate_date!(Date.strptime(heading[1], "%B %d, %Y").iso8601)
    raise InvalidData, "test election" if metadata.match?(/\b(?:test|sample|rehearsal)\b/i)
    data = body.is_a?(Array) ? body : JSON.parse(body)
    raise InvalidData, "expected California results array" unless data.is_a?(Array)
    units = data.filter_map do |contest|
      title = contest.fetch("raceTitle")
      match = title.match(/\AUnited States Representative District (\d+) - (.+) Results\z/)
      raise InvalidData, "unexpected California contest" unless match
      next if match[2] == "Districtwide"
      raise InvalidData, "unknown California geography" unless match[2].end_with?(" County")
      unit = empty_unit("CA-#{format('%02d', match[1].to_i)}", match[2])
      candidates = contest.fetch("candidates")
      names = candidates.map { |candidate| candidate.fetch("Name") }
      raise InvalidData, "missing or duplicate candidate" if names.empty? || names.any? { |n| n.to_s.empty? } || names.uniq != names
      candidates.each do |candidate|
        value = candidate.fetch("Votes")
        raise InvalidData, "invalid California vote count" unless value.is_a?(String) && value.match?(/\A(?:\d+|\d{1,3}(?:,\d{3})+)\z/)
        add_votes(unit, candidate.fetch("Party"), value.delete(","))
      end
      unit
    end
    # ReportingTime is an offset-less local time. Do not invent UTC or infer
    # finality from the precinct Reporting string.
    result = output(units)
    result["source_time_text"] = data.map { |contest| contest["ReportingTime"] }.compact.uniq.join("; ")
    result
  rescue JSON::ParserError, Date::Error, KeyError, TypeError, NoMethodError => error
    raise InvalidData, "invalid California results: #{error.message}"
  end
end
