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

      module_function

      def albers_usa(state)
        INSETS.fetch(state, LOWER_48)
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
