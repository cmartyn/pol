module Site
  module Maps
    # A district's Shape on any canvas, shared by the national House map and a
    # House race page's state map.
    module DistrictShape
      # Every modelled House race runs on generic dem/rep sides (see
      # RacesHelper#house_margin), so no candidates are loaded for these.
      SIDES = %w[dem rep].freeze

      module_function

      def build(boundary, canvas, race, forecasts, interactive: true)
        cx, cy = canvas.centroid(boundary)
        attributes = { key: "#{boundary.state}-#{boundary.district}", d: canvas.path(boundary), cx: cx, cy: cy }
        return Shape.new(**attributes, fills: Forecasts::VARIANTS.index_with { Palette::NO_RACE }) unless race

        fills = Forecasts::VARIANTS.index_with { |variant| Palette.fill(race: race, forecast: forecasts[variant][race.id]) }
        return Shape.new(**attributes, fills: fills) unless interactive

        Shape.new(
          **attributes,
          slug: race.slug,
          fills: fills,
          tips: Forecasts::VARIANTS.index_with { |variant| Tips.for(race, forecasts[variant][race.id], sides: SIDES) }
        )
      end
    end
  end
end
