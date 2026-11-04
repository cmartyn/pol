class ElectionNight::Sources::ArkansasTally < ElectionNight::Sources::Base
  FEDERAL_CONTEST = /\AU\.S\. (?:Senate|Congress District \d+)\z/
  COMPONENT_TYPES = [ "Absentee", "Election Day", "Early Voting" ].freeze
  TOTAL_TYPE = "TV - Total Votes".freeze
  PRUNE_DETAILS = lambda do |value|
    if value.is_a?(Hash)
      # A county has LocationID and its own Choices. Its nested Locations are
      # precinct repetitions. Keep the county, release those descendants.
      value.delete("Locations") if value.key?("LocationID")
      return nil if value.key?("ContestName") && !value["ContestName"].to_s.match?(FEDERAL_CONTEST)
    end
    value
  end
  private_constant :PRUNE_DETAILS

  def parse(body, metadata:)
    raise InvalidData, "Arkansas-only source" unless state == "AR"
    data = body.is_a?(Hash) ? body : JSON.parse(body, on_load: PRUNE_DETAILS)
    info = document(metadata)
    election = info.fetch("response")
    id = data.fetch("ElectionData").fetch("ElectionID")
    raise InvalidData, "conflicting election IDs" unless id == election.fetch("id") && id == info.fetch("electionID")
    validate_date!(election.fetch("date"))
    name = election.fetch("name")
    raise InvalidData, "not a production general election" unless name.match?(/\bGeneral\b/) && !name.match?(/\b(?:test|sample|rehearsal|primary|preview)\b/i)
    raise InvalidData, "test election" if data.dig("ElectionData", "IsTest") == true || election["isTest"] == true
    raise InvalidData, "metadata error" unless info["errorMessage"].nil? || info["errorMessage"].empty?
    county_metadata = election.fetch("locations")
    parties = election.fetch("parties")
    vote_types = election.fetch("voteTypes").to_h do |type_id, type|
      raise InvalidData, "conflicting vote type ID" unless type.fetch("voteTypeID") == type_id
      [ type_id, type.fetch("description") ]
    end
    units = []
    races = []
    data.fetch("ContestData").compact.each do |contest|
      next unless contest.fetch("ContestName").match?(FEDERAL_CONTEST)
      key = contest["ContestName"] == "U.S. Senate" ? "AR-S" : "AR-#{format('%02d', contest['ContestName'].split.last.to_i)}"
      raise InvalidData, "duplicate federal contest" if races.include?(key)
      races << key
      roster = choice_ids(contest.fetch("Choices"))
      locations = contest.fetch("Locations")
      raise InvalidData, "missing county results" if locations.empty?
      locations.each do |county_id, county|
        raise InvalidData, "unknown county FIPS" unless county_id.match?(/\A05\d{3}\z/) && county_metadata.key?(county_id)
        official = county_metadata.fetch(county_id)
        raise InvalidData, "conflicting county identity" unless county.fetch("LocationID") == county_id && official.fetch("locationID") == county_id && unit_key(county.fetch("LocationName")) == unit_key(official.fetch("locationName"))
        raise InvalidData, "conflicting county contest" unless county.fetch("ContestID") == contest.fetch("ContestID")
        choices = county.fetch("Choices")
        raise InvalidData, "incomplete candidate roster" unless choice_ids(choices) == roster
        writeins = county.fetch("WriteinChoices")
        if writeins.any? && choices.any? { |choice| parties.fetch(choice.fetch("PartyID")).fetch("partyName") == "Write-In" }
          raise InvalidData, "ambiguous aggregate and named write-ins"
        end
        unit = empty_unit(key, official.fetch("locationName"))
        choice_ids(choices + writeins)
        (choices + writeins).each do |choice|
          party = parties.fetch(choice.fetch("PartyID")).fetch("partyName")
          add_votes(unit, party, candidate_votes(choice.fetch("Votes"), vote_types))
        end
        units << unit
      end
    end
    output(units, published_at: timestamp(info["lastUpdated"]))
  rescue JSON::ParserError, KeyError, TypeError, NoMethodError => error
    raise InvalidData, "invalid Arkansas Tally results: #{error.message}"
  end

  private
    def choice_ids(choices)
      ids = choices.map { |choice| choice.fetch("ChoiceID") }
      raise InvalidData, "missing or duplicate candidate IDs" if ids.empty? || ids.any? { |id| id.to_s.empty? } || ids.uniq.size != ids.size
      ids.sort
    end

    def candidate_votes(votes, vote_types)
      ids = votes.map { |vote| vote.fetch("VoteTypeID") }
      raise InvalidData, "duplicate vote type" unless ids.uniq.size == ids.size
      labels = ids.map { |id| vote_types.fetch(id) }
      unless labels == [ TOTAL_TYPE ] || labels.sort == COMPONENT_TYPES.sort
        raise InvalidData, "unknown, missing or overlapping vote types"
      end
      votes.sum { |vote| count(vote.fetch("Votes")) }
    end
end
