# New York fusion ballots list the same person under several party lines.
# Consolidate only exact names shared with a major-party line in that contest;
# an unrecognized minor-party candidate remains an other-party candidate.
class ElectionNight::Sources::NewYorkCounty < ElectionNight::Sources::EnhancedVoting
  def parse(body)
    raise InvalidData, "New York county source requires NY" unless state == "NY"
    data = document(body)
    locals = data.fetch("localResults")
    locals = [ data.fetch("results") ] if locals.empty?
    locals.each do |local|
      local.fetch("ballotItems").each do |contest|
        next unless race_key(contest.fetch("name"))
        candidates = contest.fetch("ballotOptions")
        major_parties = {}
        candidates.each do |candidate|
          party = candidate.fetch("politicalParty")
          next if party_key(party) == "other_votes"
          name = candidate_name(candidate)
          if major_parties[name] && major_parties[name] != party
            raise InvalidData, "ambiguous fusion candidate"
          end
          major_parties[name] = party
        end
        candidates.each do |candidate|
          candidate["politicalParty"] = major_parties.fetch(candidate_name(candidate), candidate["politicalParty"])
        end
      end
    end
    super(data)
  rescue KeyError, TypeError, NoMethodError => error
    raise InvalidData, "invalid New York county schema: #{error.message}"
  end

  private
    def race_key(name, presidential: false)
      super(name.to_s.gsub(/(\d+(?:st|nd|rd|th)) Congressional District/i, '\1 District'), presidential: presidential)
    end

    def candidate_name(candidate)
      candidate.fetch("name").strip.sub(/\A(?:DEM|REP|CON|WOR|VAF|IND|GRE|LIB)\s+/i, "").upcase.gsub(/\s+/, " ")
    end
end
