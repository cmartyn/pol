module Ingest
  # Upserts a race's candidates against a verified entry list, then prunes
  # whoever fell off it. Extracted from SeedRaces so SeedRaces' Senate sync
  # and the (future) House daily job call one implementation instead of
  # two that could drift apart.
  module CandidateSync
    class << self
      # entries: array of hashes with string keys — "name", "party",
      # "caucus_with" (nil-able), "incumbent" (optional, defaults false).
      # warnings: an array the caller owns; a message is appended for each
      # stale candidate kept because poll results still reference them.
      def apply(race, entries, warnings:)
        entries.each do |entry|
          candidate = race.candidates.find_or_initialize_by(name: entry.fetch("name"))
          candidate.update!(
            party: entry.fetch("party"),
            caucus_with: entry["caucus_with"],
            incumbent: entry.fetch("incumbent", false)
          )
        end

        prune(race, entries.map { |entry| entry.fetch("name") }, warnings)
      end

      private
        # A candidate who has dropped off the verified list is removed so
        # that the poll parser's "column must name a real candidate" rule
        # keeps rejecting stale matchups — unless polls already point at
        # them, in which case the historical link is worth more than the
        # tidiness.
        def prune(race, names, warnings)
          race.candidates.where.not(name: names).find_each do |stale|
            if PollResult.exists?(candidate_id: stale.id)
              warnings << "kept #{race.slug} candidate #{stale.name.inspect}: referenced by existing poll results"
            else
              stale.destroy!
            end
          end
        end
    end
  end
end
