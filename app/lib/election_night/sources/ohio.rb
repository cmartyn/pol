require "nokogiri"

class ElectionNight::Sources::Ohio < ElectionNight::Sources::Base
  NAMESPACE = "http://grouper.ieee.org/groups/1622/groups/2/V1/1622_2-election_results_reporting.xsd".freeze

  def parse(body)
    raise InvalidData, "Ohio-only source" unless state == "OH"
    doc = Nokogiri::XML(body) { |config| config.strict.nonet }
    raise InvalidData, "DTD is not allowed" if doc.internal_subset || doc.external_subset
    root = doc.root
    raise InvalidData, "unexpected Ohio XML schema" unless root&.name == "ElectionReport" && root.namespace&.href == NAMESPACE
    # The real pre-election file is IsTest=true. Nothing from that rehearsal
    # may enter live storage/modeling, even if it contains plausible counts.
    raise InvalidData, "Ohio feed is test data or lacks an explicit production flag" unless %w[false 0].include?(root["IsTest"])
    ns = { "e" => NAMESPACE }
    raise InvalidData, "unexpected state FIPS" unless root.at_xpath("./e:Code[@Type='Fips']", ns)&.[]("Value") == "39"
    elections = root.xpath("./e:Election", ns)
    raise InvalidData, "ambiguous election" unless elections.length == 1
    election = elections.first
    validate_date!(election["Date"])

    parties = keyed(root.xpath("./e:PartyCollection/e:Party", ns))
    candidates = keyed(election.xpath("./e:CandidateCollection/e:Candidate", ns))
    all_geographies = keyed(root.xpath("./e:GpUnitCollection/e:GpUnit", ns))
    counties = all_geographies.select { |_id, unit| unit["Type"] == "County" && unit["IsElectoralDistrict"] == "false" }
    raise InvalidData, "missing county reporting units" if counties.empty?
    units, seen = {}, {}
    election.xpath("./e:ContestCollection/e:Contest", ns).each do |contest|
      key = race_key(contest["Name"])
      next unless key
      candidate_counties = []
      contest.xpath("./e:BallotSelection", ns).each do |selection|
        selection_counties = []
        ids = selection.xpath("./e:CandidateId", ns).map(&:text)
        raise InvalidData, "ambiguous federal candidate selection" unless ids.length == 1
        candidate = candidates.fetch(ids.first) { raise InvalidData, "unknown federal candidate" }
        party_id = candidate.at_xpath("./e:PartyId", ns)&.text
        party = party_id ? parties.fetch(party_id) { raise InvalidData, "unknown party" }["Abbreviation"] : nil
        selection.xpath("./e:VoteCountsCollection/e:VoteCounts", ns).each do |votes|
          next unless votes["Type"] == "Total"
          geographies = votes.xpath("./e:GpUnitId", ns).map(&:text)
          raise InvalidData, "ambiguous vote geography" unless geographies.length == 1
          geography_id = geographies.first
          raise InvalidData, "unknown vote geography" unless all_geographies.key?(geography_id)
          county = counties[geography_id]
          next unless county
          selection_counties << geography_id
          identity = [ key, geography_id, ids.first ]
          raise InvalidData, "duplicate candidate/county vote count" if seen[identity]
          seen[identity] = true
          unit = (units[[ key, geography_id ]] ||= empty_unit(key, county["Name"]))
          add_votes(unit, party, votes["Count"])
        end
        candidate_counties << selection_counties.sort
      end
      # The export scaffolds zeroes for each candidate. A missing candidate
      # in one county cannot silently become a zero and shift the margin.
      raise InvalidData, "incomplete candidate county coverage" unless candidate_counties.any? && candidate_counties.uniq.length == 1 && candidate_counties.first.any?
    end
    output(units.values, published_at: timestamp(root["GeneratedDate"]))
  rescue Nokogiri::XML::SyntaxError, KeyError, TypeError => error
    raise InvalidData, "invalid Ohio results: #{error.message}"
  end

  private
    def keyed(nodes)
      nodes.each_with_object({}) do |node, lookup|
        id = node["ObjectId"]
        raise InvalidData, "missing or duplicate object ID" if id.to_s.empty? || lookup.key?(id)
        lookup[id] = node
      end
    end
end
