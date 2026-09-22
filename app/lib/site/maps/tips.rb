module Site
  module Maps
    # Tooltip content for one race's shape in one forecast variant. Every word
    # is built here. map_chart_controller only places strings, and maps each
    # row's party to a color through charts/theme.js.
    module Tips
      # The timeline tooltip's series names.
      NAMES = { "dem" => "Dem", "rep" => "Rep", "other" => "Other" }.freeze

      module_function

      # sides: [side_a_party, side_b_party] for the margin, as Site::RaceSides
      # resolves them. also: other races on the same shape, for the footer.
      def for(race, forecast, sides:, also: nil)
        {
          header: race.name,
          subheader: rating(race, forecast),
          rows: rows(race, forecast, sides),
          footer: also && "Also on the ballot: #{also}"
        }.compact
      end

      # RacesHelper#rating_word_for's rule; lib code can't call a view helper.
      def rating(race, forecast)
        return "Uncontested" if uncontested?(race)
        return "No forecast yet" unless forecast

        Site::Format.rating_word(p_dem_win: forecast.p_dem_win, p_rep_win: forecast.p_rep_win, p_other_win: forecast.p_other_win,
                                 tossup_band_pp: Pol::Params.fetch!(:site, :tossup_band_pp))
      end

      def rows(race, forecast, sides)
        return [] if forecast.nil? || uncontested?(race)

        chances = { "dem" => forecast.p_dem_win, "rep" => forecast.p_rep_win, "other" => forecast.p_other_win }
          .select { |_, probability| probability.to_f.positive? }
          .sort_by.with_index { |(_, probability), index| [ -probability, index ] }
          .map { |party, probability| { value: Site::Format.percent(probability), label: NAMES.fetch(party), party: party, swatch: true } }
        chances << margin_row(forecast.mean_margin, sides) unless forecast.mean_margin.nil?
        chances
      end

      def margin_row(margin, sides)
        side_a, side_b = sides
        rounded = margin.round(1)
        party = rounded.zero? ? nil : Palette.party_key(rounded.positive? ? side_a : side_b)
        { value: Site::Format.margin(margin, side_a_party: side_a, side_b_party: side_b), label: "estimated margin", party: party, swatch: false }
      end

      def uncontested?(race)
        race.uncontested? && race.uncontested_party.present?
      end
    end
  end
end
