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
      #
      # prune: :all (default) treats entries as the whole verified ballot —
      # the Senate path's db/seed_data/senate_2026.yml is a hand-maintained,
      # fully-verified record, so anyone missing from it is gone for real.
      # prune: :listed_parties is for a source that names only the leading
      # candidates per party (the House daily sync's Wikipedia infobox): a
      # hand-added minor candidate in a party the page never mentions is left
      # alone, because only the parties entries actually cover are
      # authoritative for this run.
      def apply(race, entries, warnings:, prune: :all)
        entries.each do |entry|
          candidate = race.candidates.find_or_initialize_by(name: entry.fetch("name"))
          candidate.update!(
            party: entry.fetch("party"),
            caucus_with: entry["caucus_with"],
            incumbent: entry.fetch("incumbent", false)
          )
        end

        prune_stale(race, entries, prune, warnings)
      end

      private
        # A candidate who has dropped off the list this run treats as
        # authoritative is removed so that the poll parser's "column must
        # name a real candidate" rule keeps rejecting stale matchups —
        # unless polls already point at them, in which case the historical
        # link is worth more than the tidiness.
        def prune_stale(race, entries, prune, warnings)
          stale = race.candidates.where.not(name: entries.map { |entry| entry.fetch("name") })
          stale = stale.where(party: entries.map { |entry| entry.fetch("party") }) if prune == :listed_parties

          stale.find_each do |candidate|
            if PollResult.exists?(candidate_id: candidate.id)
              warnings << "kept #{race.slug} candidate #{candidate.name.inspect}: referenced by existing poll results"
            else
              candidate.destroy!
            end
          end
        end
    end
  end
end
