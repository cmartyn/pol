module Site
  module Maps
    # Pixel-space geometry for map shapes: Douglas–Peucker simplification,
    # compact SVG path data, and centroids for hover snapping.
    module Path
      module_function

      def simplify(points, tolerance)
        return points.dup if points.size <= 2 || tolerance <= 0

        keep = Array.new(points.size, false)
        keep[0] = true
        keep[-1] = true
        tolerance_sq = tolerance * tolerance
        stack = [ [ 0, points.size - 1 ] ]
        until stack.empty?
          first, last = stack.pop
          index, distance_sq = farthest(points, first, last)
          next unless index && distance_sq > tolerance_sq

          keep[index] = true
          stack.push([ first, index ], [ index, last ])
        end
        points.select.with_index { |_, index| keep[index] }
      end

      # Relative path data at one decimal: "M12.3,4l1.5,-.2…z". Deltas are
      # taken between rounded absolute positions, so the pen never drifts
      # from where each point was meant to land however long the ring.
      def encode(rings)
        rings.map { |ring| encode_ring(ring) }.join
      end

      # Tenths of a unit as the shortest decimal: 5 -> ".5", 120 -> "12".
      def number(tenths)
        whole, fraction = tenths.abs.divmod(10)
        text = if fraction.zero? then whole.to_s
        elsif whole.zero? then ".#{fraction}"
        else "#{whole}.#{fraction}"
        end
        tenths.negative? ? "-#{text}" : text
      end

      # Area-weighted center of the largest ring (shoelace formula); the
      # bounding-box center when that ring has no area.
      def centroid(rings)
        ring = rings.max_by { |candidate| signed_area(candidate).abs }
        return nil unless ring

        area = signed_area(ring)
        if area.zero?
          xs = ring.map(&:first)
          ys = ring.map(&:last)
          return [ (xs.min + xs.max) / 2.0, (ys.min + ys.max) / 2.0 ]
        end

        sum_x = 0.0
        sum_y = 0.0
        edges(ring).each do |(x0, y0), (x1, y1)|
          cross = (x0 * y1) - (x1 * y0)
          sum_x += (x0 + x1) * cross
          sum_y += (y0 + y1) * cross
        end
        [ sum_x / (6.0 * area), sum_y / (6.0 * area) ]
      end

      def signed_area(ring)
        edges(ring).sum { |(x0, y0), (x1, y1)| (x0 * y1) - (x1 * y0) } / 2.0
      end

      def farthest(points, first, last)
        ax, ay = points[first]
        bx, by = points[last]
        dx = bx - ax
        dy = by - ay
        length_sq = (dx * dx) + (dy * dy)
        best_index = nil
        best_sq = -1.0
        ((first + 1)...last).each do |index|
          px, py = points[index]
          # fdiv: integer lon/lat fixtures must not truncate the projection parameter.
          t = length_sq.zero? ? 0.0 : ((((px - ax) * dx) + ((py - ay) * dy)).fdiv(length_sq)).clamp(0.0, 1.0)
          ex = px - (ax + (t * dx))
          ey = py - (ay + (t * dy))
          distance_sq = (ex * ex) + (ey * ey)
          if distance_sq > best_sq
            best_sq = distance_sq
            best_index = index
          end
        end
        [ best_index, best_sq ]
      end

      def encode_ring(ring)
        tenths = ring.map { |x, y| [ (x * 10).round, (y * 10).round ] }
        tenths.pop if tenths.size > 1 && tenths.first == tenths.last
        start_x, start_y = tenths.first
        out = +"M#{number(start_x)},#{number(start_y)}"
        previous_x = start_x
        previous_y = start_y
        tenths.drop(1).each do |x, y|
          next if x == previous_x && y == previous_y

          out << "l#{number(x - previous_x)},#{number(y - previous_y)}"
          previous_x = x
          previous_y = y
        end
        out << "z"
      end

      def edges(ring)
        closed = ring.first == ring.last ? ring : ring + [ ring.first ]
        closed.each_cons(2)
      end
    end
  end
end
