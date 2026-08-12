# Every number-to-prose rule in the task brief's "Non-negotiable editorial/
# display rules": whole-percent probabilities, the "D+x.x" / "R+x.x" / "Even"
# margin convention, and the Tossup-vs-Favors rating word. Pure functions over
# plain values — no ActiveRecord, no queries — so every rule the brief writes
# down is a one-line unit test rather than a rendered-HTML assertion.
module Site
  module Format
    PARTY_LETTER = { "dem" => "D", "rep" => "R", "ind" => "I", "other" => "O" }.freeze
    PARTY_LABEL  = { "dem" => "Dem", "rep" => "Rep", "other" => "the independent" }.freeze

    module_function

    # 0.7183 -> "72%". Whole percentages only, per the brief.
    def percent(probability)
      "#{(probability * 100).round}%"
    end

    # 0.7183 -> "72 in 100" — the "X in 100" phrasing the brief wants in leads.
    def x_in_100(probability)
      "#{(probability * 100).round} in 100"
    end

    # `value` is side_a minus side_b, in percentage points (the same
    # convention every margin in this codebase uses). side_a_party/
    # side_b_party are "dem"/"rep"/"ind"/"other" strings, resolved by
    # Site::RaceSides — usually dem/rep, except the three 2026 Senate races
    # where no Democrat is on the ballot (docs/BUILD_NOTES.md Phase 3 §C4),
    # where side_a is the independent standing in the anti-Republican slot.
    #
    # Rounds to one decimal before deciding "Even" so a margin that rounds to
    # 0.0 (in either direction) reads as neutral rather than falsely
    # crediting a side with +0.0.
    def margin(value, side_a_party:, side_b_party:)
      rounded = value.round(1)
      return "Even" if rounded.zero?

      party = rounded.positive? ? side_a_party : side_b_party
      letter = PARTY_LETTER.fetch(party.to_s, "?")
      format("%s+%.1f", letter, rounded.abs)
    end

    # A pollster house effect, on the same convention as every other margin
    # on this site: +0.8 renders "D+0.8" and means the pollster's polls run
    # 0.8 points more Democratic than the field. Always dem/rep, whatever
    # race a residual came from — a house effect is a property of the house,
    # not of any one contest, and it is pooled across all of them.
    def house_effect(value)
      margin(value, side_a_party: "dem", side_b_party: "rep")
    end

    # "Tossup" when the leading side's win probability is at or under the
    # tossup band (site.tossup_band_pp, e.g. 65.0); otherwise
    # "Favors {Party}". `tossup_band_pp` is points (0..100), matching how
    # it's stored in config/model_params.yml. An uncontested race is a
    # Race-level fact this function doesn't see — callers special-case it
    # before reaching here.
    def rating_word(p_dem_win:, p_rep_win:, p_other_win:, tossup_band_pp:)
      leader = [ [ "dem", p_dem_win ], [ "rep", p_rep_win ], [ "other", p_other_win ] ].max_by { |_, p| p }
      return "Tossup" if leader.last * 100.0 <= tossup_band_pp

      "Favors #{PARTY_LABEL.fetch(leader.first)}"
    end

    # The percentile-interval strip: "5th–95th" plus each end formatted as a
    # margin. `percentiles` is the forecasts.margin_percentiles hash (string
    # keys "5".."95", as the simulator writes it).
    def percentile_interval(percentiles, side_a_party:, side_b_party:, low: "5", high: "95")
      {
        label: "#{low.to_i.ordinalize}–#{high.to_i.ordinalize}",
        low: margin(percentiles.fetch(low), side_a_party: side_a_party, side_b_party: side_b_party),
        high: margin(percentiles.fetch(high), side_a_party: side_a_party, side_b_party: side_b_party)
      }
    end

    # "as of {model run time}", the timestamp every forecast figure carries.
    def as_of(time)
      "as of #{time.strftime('%b %-d, %Y, %-I:%M %p %Z')}"
    end
  end
end
