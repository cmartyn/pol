# The election-night model uses aggregate counts. Results pages separately
# read the provider's named candidates and explicit decision from the same
# archived response, after checking it against the pinned federal race.
class PostElection::CivicReport < ElectionNight::Sources::CivicApi
  def read(body, race_key:, url:, fetched_at:)
    data = document(body)
    raise InvalidData, "unexpected result contest" unless validated_race(data) == race_key
    rows = data.fetch("candidates")
    candidate_counts(rows, require_ids: true)
    published = Time.iso8601(data.fetch("last_updated"))
    raise InvalidData, "report timestamp is in the future" if published > fetched_at + 5.minutes
    votes = rows.map do |candidate|
      party = candidate.fetch("party").strip
      { "name" => candidate.fetch("name").strip, "party" => party_code(party), "party_label" => party,
        "votes" => count(candidate.fetch("votes")) }
    end
    call = decision(data, rows, votes, published)
    { votes: votes, reported_at: published, returns_url: url,
      provider_call: call&.merge("source" => "civicAPI", "url" => url) }
  rescue KeyError, ArgumentError, TypeError => error
    raise InvalidData, "invalid result report: #{error.message}"
  end

  private
    def party_code(label)
      return "ind" if %w[ind independent].include?(label.downcase)

      party_key(label).delete_suffix("_votes")
    end

    def decision(data, rows, votes, published)
      return if published < ElectionNight::Prior::POLL_CLOSE_CUTOFF
      return { "status" => "under_review" } if data["is_disputed"] == true
      return unless data["is_disputed"] == false && rows.all? { |c| [ true, false ].include?(c["winner"]) }

      winners = rows.each_index.select { |index| rows[index]["winner"] }
      return { "status" => "uncalled" } if winners.empty? && data["called_at"].blank?
      return { "status" => "under_review" } unless winners.one?

      # Some explicit calls carry no time. Never substitute a vote update or
      # our retrieval time for the decision desk's call time.
      at = Time.iso8601(data["called_at"]) if data["called_at"].present?
      return { "status" => "under_review" } if at && !at.between?(ElectionNight::Prior::POLL_CLOSE_CUTOFF, published)

      { "status" => "projected", "winner" => votes.fetch(winners.first).slice("name", "party"),
        "decided_at" => at&.utc&.iso8601 }.compact
    end
end
