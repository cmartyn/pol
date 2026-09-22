module Site
  module Maps
    # The national House map: every district on the cycle's lines. Each
    # state's districts are clipped to its shoreline outline (the legal
    # district lines run out into lakes and bays), and the outline is stroked
    # on top. Builders iterate boundaries, not races, so a race with no
    # boundary is simply not drawn.
    class HouseMap
      WIDTH = 960
      TOLERANCE = 0.5

      def self.build(key: "house", tolerance: TOLERANCE, interactive: true)
        new(key: key, tolerance: tolerance, interactive: interactive).build
      end

      def initialize(key:, tolerance:, interactive:)
        @key = key
        @tolerance = tolerance
        @interactive = interactive
      end

      def build
        outlines = Boundary.outlines.order(:state).to_a
        return nil if outlines.empty?

        districts_by_state = Boundary.districts.order(:state, :district).to_a.group_by(&:state)
        canvas = Canvas.national(outlines, width: WIDTH, tolerance: @tolerance)
        races = Race.house.to_a.index_by { |race| [ race.state, race.district ] }
        forecasts = Forecasts.latest_by_variant(races.values.map(&:id))

        groups = outlines.filter_map do |outline|
          districts = districts_by_state.fetch(outline.state, [])
          next if districts.empty?

          {
            state: outline.state,
            clip_id: "#{@key}-clip-#{outline.state}",
            outline_id: "#{@key}-outline-#{outline.state}",
            outline_d: canvas.path(outline),
            shapes: districts.map { |district| DistrictShape.build(district, canvas, races[[ district.state, district.district ]], forecasts, interactive: @interactive) },
            highlight_d: nil
          }
        end

        { key: @key, view_box: canvas.view_box, aria_label: aria_label, interactive: @interactive, groups: groups, legend: Palette.legend }
      end

      private
        def aria_label
          "Map of all #{Ingest::SeedRaces::HOUSE_DISTRICTS} House districts on the #{Ingest::Sources.cycle} lines, " \
            "each shaded by its race's win probability"
        end
    end
  end
end
