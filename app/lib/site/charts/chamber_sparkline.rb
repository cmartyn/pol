# The homepage chamber card's trend line, drawn in Ruby so it ships as plain
# SVG inside the card's cached fragment: no JavaScript, no payload, and a
# cache hit costs nothing.
#
# The plot is WIDTH x HEIGHT user units, stretched to the card's width by
# the partial (preserveAspectRatio="none", non-scaling strokes). x runs from
# the first run to election day, so the days still to come show as empty
# room at the right; y runs from 100% at the top to 0% at the bottom.
#
# 1,200+ runs is more points than the card has pixels, so each pixel column
# keeps only its first, lowest, highest and last run, in the order they
# happened. That is not smoothing: every other run in the column lies between
# its lowest and highest, so a one-run spike survives, and the first and last
# keep the line starting at the captioned values and ending on the current
# run, which is the figure printed above it.
module Site
  module Charts
    class ChamberSparkline
      WIDTH = 200
      HEIGHT = 64
      PAD = 3

      def self.build(history, variant:)
        new(history, variant).build
      end

      def initialize(history, variant)
        @history = history
        @variant = variant.to_sym
      end

      def build
        entries = @history.entries
        return nil if entries.empty?

        first = entries.first.row(@variant)
        last = entries.last.row(@variant)
        start_label = entries.first.at.strftime("%b %-d")

        {
          width: WIDTH,
          height: HEIGHT,
          midline_y: y(0.5),
          dem: line(entries) { |row| row.p_dem }.merge(start_label: Site::Format.percent(first.p_dem)),
          rep: line(entries) { |row| row.p_rep }.merge(start_label: Site::Format.percent(first.p_rep)),
          # Unlabelled on the card: a key under the line did not read as
          # describing these marks. Each names itself on hover instead.
          corrections: @history.corrections.map do |correction|
            { x: x(correction.at), label: "Data correction, #{correction.at.strftime('%b %-d')}" }
          end,
          start_label: start_label,
          aria_label: "Chance of #{@history.chamber.capitalize} control in each model run since #{start_label}: " \
            "Democrats from #{Site::Format.percent(first.p_dem)} to #{Site::Format.percent(last.p_dem)}, " \
            "Republicans from #{Site::Format.percent(first.p_rep)} to #{Site::Format.percent(last.p_rep)}."
        }
      end

      private
        def line(entries, &value)
          points = entries.map { |entry| [ x(entry.at), value.call(entry.row(@variant)) ] }
          kept = points.chunk_while { |a, b| a.first.floor == b.first.floor }.flat_map do |column|
            keep = [ column.first, column.min_by(&:last), column.max_by(&:last), column.last ]
            column.select { |point| keep.any? { |kept_point| kept_point.equal?(point) } }
          end
          plotted = kept.map { |px, p| [ px, y(p) ] }
          final_x, final_y = plotted.last

          path = "M" + plotted.map { |px, py| "#{number(px)},#{number(py)}" }.join("L")
          # The current value's dot is HTML positioned over the stretched
          # SVG, so it stays round: left as a share of the width, top in
          # pixels (the plot is drawn at its own height).
          dot = { left_pct: (final_x / WIDTH * 100).round(1), top: final_y }

          { points: plotted, path: path, end: dot }
        end

        def x(time)
          span = domain_end - domain_start
          return 0.0 unless span.positive?

          ((time - domain_start) / span * WIDTH).round(1)
        end

        def y(probability)
          (PAD + (1 - probability) * (HEIGHT - 2 * PAD)).round(1)
        end

        def domain_start = @history.entries.first.at

        # Runs after election day, if any, extend the axis rather than fall
        # off its edge.
        def domain_end = [ @history.election_at, @history.entries.last.at ].max

        def number(value)
          format("%g", value)
        end
    end
  end
end
