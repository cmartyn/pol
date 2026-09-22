module Site
  module Maps
    # The national Senate map: every state outline, filled by its Senate race
    # on this cycle's ballot. With `highlight:` it is a Senate race page's
    # locator instead, with no links or tooltips and only the race's own
    # state colored and outlined.
    class SenateMap
      WIDTH = 960
      TOLERANCE = 0.5
      LOCATOR_TOLERANCE = 3.0
      NO_RACE_LABEL = "No Senate race this year".freeze

      def self.build(highlight: nil, key: nil, tolerance: nil)
        new(
          highlight: highlight,
          key: key || (highlight ? "senate-locator" : "senate"),
          tolerance: tolerance || (highlight ? LOCATOR_TOLERANCE : TOLERANCE)
        ).build
      end

      def initialize(highlight:, key:, tolerance:)
        @highlight = highlight
        @key = key
        @tolerance = tolerance
      end

      def build
        outlines = Boundary.outlines.order(:state).to_a
        return nil if outlines.empty?

        canvas = Canvas.national(outlines, width: WIDTH, tolerance: @tolerance)
        shapes = if @highlight
          forecasts = Forecasts.latest_by_variant([ @highlight.id ])
          outlines.map { |outline| shape_for(outline, canvas, [], forecasts) }
        else
          races_by_state = Race.senate.includes(:candidates).order(:slug).to_a.group_by(&:state)
          forecasts = Forecasts.latest_by_variant(races_by_state.values.flatten.map(&:id))
          outlines.map { |outline| shape_for(outline, canvas, races_by_state.fetch(outline.state, []), forecasts) }
        end

        {
          key: @key,
          view_box: canvas.view_box,
          aria_label: aria_label,
          interactive: @highlight.nil?,
          groups: [ { state: nil, clip_id: nil, outline_id: nil, outline_d: nil, shapes: shapes, highlight_d: highlight_d(shapes) } ],
          legend: @highlight ? nil : Palette.legend(no_race_label: NO_RACE_LABEL)
        }
      end

      private
        def shape_for(outline, canvas, races, forecasts)
          cx, cy = canvas.centroid(outline)
          attributes = { key: outline.state, d: canvas.path(outline), cx: cx, cy: cy }
          return locator_shape(attributes, outline, forecasts) if @highlight

          race = races.min_by { |candidate| closeness(forecasts[:excl_internals][candidate.id]) }
          return Shape.new(**attributes, fills: Forecasts::VARIANTS.index_with { Palette::NO_RACE }) unless race

          sides = Site::RaceSides.for(race.candidates)
          others = (races - [ race ]).map { |other| display_name(other) }.to_sentence.presence
          Shape.new(
            **attributes,
            slug: race.slug,
            fills: Forecasts::VARIANTS.index_with { |variant| Palette.fill(race: race, forecast: forecasts[variant][race.id]) },
            tips: Forecasts::VARIANTS.index_with { |variant| Tips.for(race, forecasts[variant][race.id], sides: sides, also: others) }
          )
        end

        def locator_shape(attributes, outline, forecasts)
          fills = Forecasts::VARIANTS.index_with do |variant|
            next Palette::NO_RACE unless outline.state == @highlight.state

            Palette.fill(race: @highlight, forecast: forecasts[variant][@highlight.id])
          end
          Shape.new(**attributes, fills: fills)
        end

        # The leading side's win probability: the lower, the closer the race.
        # A race with no forecast sorts after every forecast one.
        def closeness(forecast)
          return 2.0 unless forecast

          Site::Format.leader(p_dem_win: forecast.p_dem_win, p_rep_win: forecast.p_rep_win, p_other_win: forecast.p_other_win).last
        end

        def display_name(race)
          race.special? ? "#{race.name} (special)" : race.name
        end

        def highlight_d(shapes)
          return nil unless @highlight

          shapes.find { |shape| shape.key == @highlight.state }&.d
        end

        def aria_label
          if @highlight
            "Locator map with #{Race::STATE_NAMES.fetch(@highlight.state, @highlight.state)} highlighted"
          else
            "Map of the Senate races on the #{Ingest::Sources.cycle} ballot, each state shaded by its race's win probability"
          end
        end
    end
  end
end
