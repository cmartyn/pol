module Site
  module Maps
    # One map's pixel frame: it projects boundaries, fits them into a width
    # (and optional max height), and hands back simplified path data. The
    # frame is fitted around the boundaries passed in (every outline for a
    # national map, one outline for a state map); anything else drawn on the
    # canvas lands in that same frame.
    class Canvas
      attr_reader :width, :height

      # For maps drawn at about half their 960-unit frame, such as the
      # dashboard cards, 2 units is about 1 CSS pixel.
      SMALL_TOLERANCE = 2.0

      def self.national(outlines, width: 960, tolerance: 0.5, padding: 2)
        new(outlines, projector: ->(boundary) { Projection.albers_usa(boundary.state) },
            width: width, max_height: nil, padding: padding, tolerance: tolerance)
      end

      def self.state(outline, width: 600, max_height: 480, tolerance: 0.5, padding: 4)
        projection = Projection.fitted(Projection.inset_rings(outline.state, outline.rings))
        new([ outline ], projector: ->(_boundary) { projection },
            width: width, max_height: max_height, padding: padding, tolerance: tolerance)
      end

      def initialize(frame_boundaries, projector:, width:, max_height:, padding:, tolerance:)
        @projector = projector
        @tolerance = tolerance
        @projected = {}
        @pixels = {}
        @width = width

        xs = []
        ys = []
        frame_boundaries.each do |boundary|
          projected_rings(boundary).each do |ring|
            ring.each do |x, y|
              xs << x
              ys << y
            end
          end
        end
        raise ArgumentError, "no points to frame" if xs.empty?

        @min_x, max_x = xs.minmax
        @min_y, max_y = ys.minmax
        span_x = [ max_x - @min_x, Float::EPSILON ].max
        span_y = [ max_y - @min_y, Float::EPSILON ].max
        inner_width = width - (2 * padding)
        @scale = inner_width / span_x
        @scale = [ @scale, (max_height - (2 * padding)) / span_y ].min if max_height
        @offset_x = padding + ((inner_width - (span_x * @scale)) / 2.0)
        @offset_y = padding
        # round(6) first: a height-limited frame computes max_height back out
        # of a float product, and 300.0000001.ceil would be 301.
        @height = ((span_y * @scale) + (2 * padding)).round(6).ceil
        @height = [ @height, max_height ].min if max_height
      end

      def view_box
        "0 0 #{@width} #{@height}"
      end

      # Rings smaller than the tolerance are dropped, but a boundary never
      # disappears entirely: when every ring is sub-pixel (Manhattan's
      # districts on the national map), the largest is kept unsimplified so
      # hover snapping and keyboard stepping can still reach it.
      def path(boundary)
        rings = pixel_rings(boundary)
        return "" if rings.empty?

        kept = rings.reject { |ring| tiny?(ring) }.filter_map do |ring|
          simple = Path.simplify(ring, @tolerance)
          simple if simple.uniq.size >= 3
        end
        kept = [ rings.max_by { |ring| Path.signed_area(ring).abs } ].compact if kept.empty?
        Path.encode(kept)
      end

      def centroid(boundary)
        rings = pixel_rings(boundary)
        return nil if rings.empty?

        Path.centroid(rings)&.map { |value| value.round(1) }
      end

      private
        def projected_rings(boundary)
          @projected[boundary] ||= begin
            projection = @projector.call(boundary)
            Projection.inset_rings(boundary.state, boundary.rings).map { |ring| ring.map { |lon, lat| projection.call(lon, lat) } }
          end
        end

        def pixel_rings(boundary)
          @pixels[boundary] ||= projected_rings(boundary).map do |ring|
            ring.map { |x, y| [ @offset_x + ((x - @min_x) * @scale), @offset_y + ((y - @min_y) * @scale) ] }
          end
        end

        def tiny?(ring)
          xs = ring.map(&:first)
          ys = ring.map(&:last)
          (xs.max - xs.min) < @tolerance && (ys.max - ys.min) < @tolerance
        end
    end
  end
end
