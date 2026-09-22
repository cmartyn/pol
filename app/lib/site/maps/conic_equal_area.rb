module Site
  module Maps
    # d3-geo's conic equal-area projection (geoConicEqualArea), ported so the
    # server can draw maps without Node. It is d3's projection() pipeline:
    # rotate the longitude (wrapping into ±180°, which is what puts Attu at
    # +173° beside the rest of Alaska), project, then scale and translate
    # relative to the projected center, with y flipped to grow downward as
    # SVG's does. The tests pin it to d3's own output.
    class ConicEqualArea
      RADIANS = Math::PI / 180

      attr_reader :parallels

      def initialize(parallels:, rotate:, center: [ 0.0, 0.0 ], scale: 1.0, translate: [ 0.0, 0.0 ])
        @parallels = parallels
        phi0, phi1 = parallels.map { |degrees| degrees * RADIANS }
        sin0 = Math.sin(phi0)
        @n = (sin0 + Math.sin(phi1)) / 2
        raise ArgumentError, "parallels #{parallels.inspect} straddle the equator symmetrically" if @n.abs < 1e-6

        @c = 1 + (sin0 * ((2 * @n) - sin0))
        @r0 = Math.sqrt(@c) / @n
        @rotate = rotate * RADIANS
        @scale = scale
        @translate_x, @translate_y = translate
        @center_x, @center_y = raw(center[0] * RADIANS, center[1] * RADIANS)
      end

      # [x, y] for a longitude and latitude in degrees.
      def call(lon, lat)
        x, y = raw(wrap((lon * RADIANS) + @rotate), lat * RADIANS)
        [ @translate_x + (@scale * (x - @center_x)), @translate_y - (@scale * (y - @center_y)) ]
      end

      private
        def raw(longitude, latitude)
          r = Math.sqrt(@c - (2 * @n * Math.sin(latitude))) / @n
          [ r * Math.sin(longitude * @n), @r0 - (r * Math.cos(longitude * @n)) ]
        end

        def wrap(longitude)
          if longitude > Math::PI then longitude - (2 * Math::PI)
          elsif longitude < -Math::PI then longitude + (2 * Math::PI)
          else longitude
          end
        end
    end
  end
end
