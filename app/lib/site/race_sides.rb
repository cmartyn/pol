# Which two parties a race's margin is measured between, for
# Site::Format.margin. Mirrors Forecast::RaceModel#side_a/#side_b just
# closely enough to label a margin correctly: side_a is the Democrat, or —
# Idaho, Nebraska and South Dakota in 2026, the live cases — the independent
# standing in the anti-Republican slot when no Democrat is on the ballot;
# side_b is the Republican. This does not re-simulate or re-derive a
# forecast, and it isn't a duplicate of the engine's logic for its own sake:
# it reads the same candidate rows the engine does, for the same reason
# (there's no other honest way to know which letter a positive number
# belongs to). See docs/BUILD_NOTES.md Phase 3 §C4.
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

      side_a = dem ? "dem" : (top_minor_party(candidates) || "dem")
      side_b = rep ? "rep" : "rep"

      [ side_a, side_b ]
    end

    # Tie-break must stay byte-for-byte identical to Forecast::RaceModel
    # #top_minor_candidate's sort key (app/lib/forecast/race_model.rb): an
    # independent always outranks another minor party, id only breaking ties
    # within the same tier. A plain `.min_by(&:id)` here once diverged from
    # that — dormant while no live race runs two minor candidates, but a real
    # mislabel waiting to happen, since this value picks which candidate a
    # displayed margin is credited to while the engine's matching pick
    # decides what the forecast numbers actually measure. If the engine's
    # sort key ever changes, this one must change with it.
    def top_minor_party(candidates)
      candidates
        .reject { |candidate| MAJOR_PARTIES.include?(candidate.party) }
        .min_by { |candidate| [ candidate.party == "ind" ? 0 : 1, candidate.id ] }
        &.party
    end
  end
end
