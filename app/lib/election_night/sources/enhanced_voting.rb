class ElectionNight::Sources::EnhancedVoting < ElectionNight::Sources::Base
  def parse(body)
    parse_export(body, presidential: false)
  end

  def parse_baselines(body)
    historical = self.class.new(state: state, election_date: "2024-11-05")
    data = document(body)
    result = historical.send(:parse_export, data, presidential: true)
    # Preserve actual historical county portions of congressional districts.
    # The caller must verify that the district boundaries are unchanged.
    result["house_units"] = historical.send(:parse_export, data, presidential: false, allow_empty: true)["units"].reject { |unit| unit["race_key"].end_with?("-S") }
    result
  end

  private
    def document(body)
      body.is_a?(Hash) ? body : ElectionNight::SummaryJson.parse(body)
    rescue JSON::ParserError => error
      raise InvalidData, "invalid JSON: #{error.message}"
    end

    def parse_export(body, presidential:, allow_empty: false)
      data = document(body)
      validate_date!(data.fetch("electionDate"))
      raise InvalidData, "test election" if data["isTest"] == true || data["isProduction"] == false || data["electionName"].to_s.match?(/\btest\b/i)
      locals = data.fetch("localResults")
      raise InvalidData, "localResults must be an array" unless locals.is_a?(Array)
      # A county-hosted export has no child localities; its root is the county.
      # A statewide root is never counted alongside its county children.
      if locals.empty?
        root = data.fetch("results")
        raise InvalidData, "state export has no county results" unless root.fetch("name").match?(/\b(?:county|city)\z/i)
        locals = [ root ]
      end
      units = locals.flat_map do |local|
        local.fetch("ballotItems").filter_map do |contest|
          key = race_key(contest.fetch("name"), presidential: presidential)
          next unless key
          unit = empty_unit(key, local.fetch("name"))
          candidates = contest.fetch("ballotOptions")
          raise InvalidData, "empty federal contest" if candidates.empty?
          ids = candidates.map { |candidate| candidate.fetch("id") }
          raise InvalidData, "duplicate candidate" unless ids.uniq.length == ids.length
          candidates.each { |candidate| add_votes(unit, candidate["politicalParty"], candidate.fetch("voteCount")) }
          # Reporting all precincts does NOT establish that late/mail ballots
          # are exhausted. Keep complete=false until explicitly verified.
          unit
        end
      end
      return { "units" => [] } if allow_empty && units.empty?
      output(units, published_at: timestamp(data["createdAt"]))
    rescue KeyError, TypeError, NoMethodError => error
      raise InvalidData, "invalid Enhanced Voting schema: #{error.message}"
    end
end
