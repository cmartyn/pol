require "base64"

class ElectionNight::Sources::Texas < ElectionNight::Sources::Base
  def parse(body, metadata:)
    # The county endpoint has no election identifier. Require companion
    # election metadata rather than trusting a caller-selected URL alone.
    meta = document(metadata)
    home = decode(meta.fetch("Home"))
    validate_date!(Date.strptime(home.fetch("ElecDate"), "%m%d%Y").iso8601)
    raise InvalidData, "test election" if home["IsTest"] == true || meta["IsTest"] == true
    data = decode(document(body).fetch("upload"))
    units = data.values.flat_map do |county|
      county.fetch("Races").values.filter_map do |contest|
        key = race_key(contest.fetch("N"))
        next unless key
        unit = empty_unit(key, county.fetch("N"))
        candidates = contest.fetch("C")
        raise InvalidData, "empty federal contest" if candidates.empty?
        candidates.each_value { |candidate| add_votes(unit, candidate["P"], candidate.fetch("V")) }
        if contest.key?("T") && count(contest["T"]) != unit["total_votes"]
          raise InvalidData, "candidate sum differs from contest total"
        end
        unit
      end
    end
    # Texas's human-readable LastUpdatedTime omits a UTC offset. Preserve it
    # separately; don't silently turn a Central timestamp into server time.
    output(units).merge("source_time_text" => home["LastUpdatedTime"])
  rescue KeyError, TypeError, NoMethodError, Date::Error => error
    raise InvalidData, "invalid Texas schema: #{error.message}"
  end

  private
    def decode(encoded)
      JSON.parse(Base64.strict_decode64(encoded))
    rescue ArgumentError, JSON::ParserError => error
      raise InvalidData, "invalid encoded results: #{error.message}"
    end
end
