module Site
  module Maps
    # Which projection draws which boundary.
    module Projection
      # d3-geo's geoAlbersUsa at its default scale and translate: the lower
      # 48 on one conic, Alaska and Hawaii each on their own, moved into d3's
      # standard insets. Chosen by the boundary's state rather than by clip
      # extent, since every boundary knows its state.
      SCALE = 1070.0
      TRANSLATE_X = 480.0
      TRANSLATE_Y = 250.0

      LOWER_48 = ConicEqualArea.new(
        parallels: [ 29.5, 45.5 ], rotate: 96, center: [ -0.6, 38.7 ],
        scale: SCALE, translate: [ TRANSLATE_X, TRANSLATE_Y ]
      )
          INSETS = {
        "AK" => ConicEqualArea.new(
          parallels: [ 55, 65 ], rotate: 154, center: [ -2, 58.5 ],
          scale: SCALE * 0.35, translate: [ TRANSLATE_X - (0.307 * SCALE), TRANSLATE_Y + (0.201 * SCALE) ]
        ),
        "HI" => ConicEqualArea.new(
          parallels: [ 8, 18 ], rotate: 157, center: [ -3, 19.9 ],
          scale: SCALE, translate: [ TRANSLATE_X - (0.205 * SCALE), TRANSLATE_Y + (0.212 * SCALE) ]
        )
      }.freeze

      # d3's geoAlbersUsa clips each sub-projection to these boxes (its
      # default frame). The clip is what leaves the Northwestern Hawaiian
      # Islands, out to Kure Atoll at −178°, off the map: kept, their specks
      # would stretch every frame they sit in across empty ocean.
      EXTENTS = {
        lower_48: [ [ TRANSLATE_X - (0.455 * SCALE), TRANSLATE_Y - (0.238 * SCALE) ], [ TRANSLATE_X + (0.455 * SCALE), TRANSLATE_Y + (0.238 * SCALE) ] ],
        "AK" => [ [ TRANSLATE_X - (0.425 * SCALE), TRANSLATE_Y + (0.120 * SCALE) ], [ TRANSLATE_X - (0.214 * SCALE), TRANSLATE_Y + (0.234 * SCALE) ] ],
        "HI" => [ [ TRANSLATE_X - (0.214 * SCALE), TRANSLATE_Y + (0.166 * SCALE) ], [ TRANSLATE_X - (0.115 * SCALE), TRANSLATE_Y + (0.234 * SCALE) ] ]
      }.freeze

      module_function

      def albers_usa(state)
        INSETS.fetch(state, LOWER_48)
      end

      # The rings d3's geoAlbersUsa would draw for a state: those whose
      # bounding-box center projects inside that state's clip extent.
      def inset_rings(state, rings)
        projection = albers_usa(state)
        (min_x, min_y), (max_x, max_y) = EXTENTS.fetch(state, EXTENTS.fetch(:lower_48))
        rings.select do |ring|
          lons = ring.map(&:first)
          lats = ring.map(&:last)
          x, y = projection.call((lons.min + lons.max) / 2.0, (lats.min + lats.max) / 2.0)
          x.between?(min_x, max_x) && y.between?(min_y, max_y)
        end
      end

      # A unit-scale conic fitted to one state: centered on its middle
      # longitude, standard parallels at 1/6 and 5/6 of its latitude range,
      # so no state is drawn rotated the way a national projection tilts the
      # ones near its edges. Canvas scales the result to pixels.
      def fitted(rings)
        points = rings.flatten(1)
        west, east = points.map(&:first).minmax
        south, north = points.map(&:last).minmax
        inset = (north - south) / 6.0
        ConicEqualArea.new(parallels: [ south + inset, north - inset ], rotate: -((west + east) / 2.0))
      end
    end
  end
end
