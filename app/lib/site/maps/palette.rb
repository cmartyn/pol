module Site
  module Maps
    # Fill colors for map shapes. PARTY is app/javascript/charts/theme.js's
    # PARTY, so a map and the charts beside it cannot disagree about Dem-blue.
    module Palette
      PARTY = { "dem" => "#1d4ed8", "rep" => "#b91c1c", "other" => "#64748b" }.freeze
      # Neutral grays: slate's blue cast reads as the palest Democratic tint.
      NO_FORECAST = "#d4d4d4".freeze
      NO_RACE = "#e5e5e5".freeze
      # How far a dead-even race is mixed from white toward its leader's
      # hue; the remaining 1 − FLOOR is spread linearly across a 50% to 100%
      # win probability.
      FLOOR = 0.2

      module_function

      def fill(race:, forecast:)
        return PARTY.fetch(party_key(race.uncontested_party)) if race.uncontested? && race.uncontested_party.present?
        return NO_FORECAST unless forecast

        party, probability = Site::Format.leader(p_dem_win: forecast.p_dem_win, p_rep_win: forecast.p_rep_win, p_other_win: forecast.p_other_win)
        shade(party, probability)
      end

      def shade(party, probability)
        strength = ((probability - 0.5) / 0.5).clamp(0.0, 1.0)
        mix(PARTY.fetch(party), FLOOR + ((1 - FLOOR) * strength))
      end

      # White blended toward `hex` by `amount`: 0 is white, 1 is `hex`.
      def mix(hex, amount)
        channels = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
        "#" + channels.map { |channel| (255 + ((channel - 255) * amount)).round.to_s(16).rjust(2, "0") }.join
      end

      # Races say dem/rep/ind/other; the palette folds ind into other.
      def party_key(party)
        PARTY.key?(party.to_s) ? party.to_s : "other"
      end

      def legend(no_race_label: nil)
        swatches = [ { label: "No forecast yet", color: NO_FORECAST } ]
        swatches << { label: no_race_label, color: NO_RACE } if no_race_label
        {
          ramps: %w[dem rep].map { |party| { label: Site::Format::PARTY_LABEL.fetch(party), from: shade(party, 0.5), to: shade(party, 1.0) } },
          swatches: swatches,
          caption: "Darker is likelier. The palest shades are tossups: the leading side wins " \
                   "#{Pol::Params.fetch!(:site, :tossup_band_pp).round}% of simulations or fewer."
        }
      end
    end
  end
end
