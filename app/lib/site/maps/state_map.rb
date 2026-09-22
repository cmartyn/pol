module Site
  module Maps
    # A House race page's map: every district in the race's state, each shaded
    # by its own forecast, with the page's own district outlined. The outline
    # sits inside the state's clip, so a coastal district's highlight never
    # traces water.
    class StateMap
      WIDTH = 600
      MAX_HEIGHT = 440
      TOLERANCE = 0.5

      def self.build(race)
        new(race).build
      end

      def initialize(race)
        @race = race
        @key = "state-#{race.state}"
      end

      def build
        outline = Boundary.outlines.find_by(state: @race.state)
        districts = Boundary.districts.where(state: @race.state).order(:district).to_a
        return nil if outline.nil? || districts.empty?

        canvas = Canvas.state(outline, width: WIDTH, max_height: MAX_HEIGHT, tolerance: TOLERANCE)
        races = Race.house.where(state: @race.state).index_by(&:district)
        forecasts = Forecasts.latest_by_variant(races.values.map(&:id))
        shapes = districts.map { |district| DistrictShape.build(district, canvas, races[district.district], forecasts) }

        {
          key: @key,
          view_box: canvas.view_box,
          aria_label: "Map of #{Race::STATE_NAMES.fetch(@race.state, @race.state)}'s congressional districts with #{@race.name} outlined",
          interactive: true,
          groups: [ {
            state: @race.state,
            clip_id: "#{@key}-clip",
            outline_id: "#{@key}-outline",
            outline_d: canvas.path(outline),
            shapes: shapes,
            highlight_d: shapes.find { |shape| shape.key == "#{@race.state}-#{@race.district}" }&.d
          } ],
          legend: nil
        }
      end
    end
  end
end
