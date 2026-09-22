module Site
  module Maps
    # The latest succeeded run's forecasts for a set of races, keyed by
    # variant, then race id. The internals view falls back to the published
    # row wherever a pre-toggle run wrote only one: the same stand-in
    # VariantsHelper#forecasts_by_variant makes for a single race.
    module Forecasts
      VARIANTS = Forecast.variants.keys.map(&:to_sym).freeze

      module_function

      def latest_by_variant(race_ids)
        published = Forecast.latest_for_races.where(race_id: race_ids).index_by(&:race_id)
        internals = Forecast.latest_for_races(variant: :incl_internals).where(race_id: race_ids).index_by(&:race_id)
        { excl_internals: published, incl_internals: published.merge(internals) }
      end
    end
  end
end
