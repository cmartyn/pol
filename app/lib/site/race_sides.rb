# Which two parties a race's margin is measured between, for
# Site::Format.margin. Mirrors Forecast::RaceModel#side_a/#side_b: side_a is
# the Democrat, or — Idaho, Nebraska and South Dakota in 2026, the live
# cases — the independent standing in the anti-Republican slot when no
# Democrat is on the ballot; side_b is the Republican, or, on the rarer
# no-Republican side, the strongest remaining minor candidate once whichever
# one side_a already claimed is excluded. This does not re-simulate or
# re-derive a forecast, and it isn't a duplicate of the engine's logic for
# its own sake: it reads the same candidate rows the engine does, for the
# same reason (there's no other honest way to know which letter a positive
# number belongs to). #top_minor_candidate below is the one tie-break both
# this module and Forecast::RaceModel call — extracted specifically so the
# two cannot silently disagree about which candidate is "the" minor one the
# way side_b once did (a hand-written copy that was missing its own fallback
# entirely). See docs/BUILD_NOTES.md Phase 3 §C4.
module Site
  module RaceSides
    MAJOR_PARTIES = %w[dem rep].freeze

    module_function

    # candidates: an array (or loaded relation) of Candidate — the caller's
    # job to preload via race.candidates(.includes) so this never queries.
    # Returns [side_a_party, side_b_party] as "dem"/"rep"/"ind"/"other".
    def for(candidates)
      candidates = candidates.to_a
      dem = candidates.find { |candidate| candidate.party == "dem" }
      rep = candidates.find { |candidate| candidate.party == "rep" }

      side_a_candidate = dem || top_minor_candidate(candidates)
      side_b_candidate = rep || top_minor_candidate(candidates, except: side_a_candidate&.name)

      [ side_a_candidate&.party || "dem", side_b_candidate&.party || "rep" ]
    end

    # The strongest non-major-party candidate, used when a major party has
    # nobody on the ballot: an independent always outranks another minor
    # party, id only breaking ties within the same tier. `except` (a
    # candidate name) keeps a second call from re-picking whichever minor
    # candidate a first call already claimed for the other side.
    #
    # Forecast::RaceModel#top_minor_candidate calls this directly rather than
    # keeping its own copy of the tie-break, so the engine and the site
    # cannot drift apart on which candidate "the" minor one is.
    def top_minor_candidate(candidates, except: nil)
      candidates
        .reject { |candidate| MAJOR_PARTIES.include?(candidate.party) || (except && candidate.name == except) }
        .min_by { |candidate| [ candidate.party == "ind" ? 0 : 1, candidate.id ] }
    end
  end
end
