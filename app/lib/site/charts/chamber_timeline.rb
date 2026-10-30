# The payload for a chamber page's "Forecast over time" chart
# (chamber_timeline_controller.js): every succeeded run's chance of control
# for each party, and its expected Democratic-caucus seats with the 5th–95th
# percentile range of its simulations.
#
# Columnar rather than one object per run. Production has 1,200+ runs and the
# chart carries two internals views, so repeating every key on every point
# would roughly double the page. Each array is aligned with `t`.
#
# As with Site::Charts::Timeline, the payload carries the words and the JS
# only places them: percentages go through Site::Format.percent, so the
# chart can never round a probability differently from the card beside it.
module Site
  module Charts
    class ChamberTimeline
      PERCENTILE_LOW = 5
      PERCENTILE_HIGH = 95

      def self.build(history)
        new(history).build
      end

      def initialize(history)
        @history = history
      end

      def build
        entries = @history.entries

        {
          chamber: @history.chamber,
          t: entries.map { |entry| milliseconds(entry.at) },
          # Site::Format.as_of's vocabulary with a middot, as the race
          # timeline's readout heads itself.
          time_labels: entries.map { |entry| entry.at.strftime("%b %-d, %Y · %-I:%M %p %Z") },
          series: {
            excl: series(entries, :excl_internals),
            incl: series(entries, :incl_internals)
          },
          corrections: @history.corrections.map do |correction|
            { index: correction.index, t: milliseconds(correction.at), label: correction.at.strftime("%b %-d") }
          end,
          election: { t: milliseconds(@history.election_at), label: "Election Day" },
          majority: {
            seats: SeatHistogram.dem_threshold(@history.chamber),
            label: SeatHistogram.majority_label(@history.chamber)
          },
          words: {
            control_panel: "Chance of control",
            seats_panel: "Expected Dem-caucus seats",
            seats_row: "expected Dem-caucus seats",
            range: "#{PERCENTILE_LOW.ordinalize}–#{PERCENTILE_HIGH.ordinalize} percentile",
            correction: "Correction",
            corrections: "Corrections",
            correction_readout: "First run after a data correction"
          },
          sparse: entries.size < 2
        }
      end

      # Nearest rank over a histogram, as Forecast::Simulator#percentile is
      # over raw draws: the smallest seat count at which the cumulative share
      # of simulations reaches `percent`. Works on counts (production) and
      # on shares (older rows and fixtures) alike. Never interpolated, so the
      # range is always seat counts some simulation actually produced.
      def self.seat_percentile(histogram, percent)
        return nil if histogram.blank?

        total = histogram.values.sum.to_f
        return nil unless total.positive?

        target = percent / 100.0
        cumulative = 0.0
        sorted = histogram.map { |seats, count| [ Integer(seats), count ] }.sort_by(&:first)
        sorted.each do |seats, count|
          cumulative += count
          return seats if cumulative / total >= target - 1e-9
        end
        sorted.last.first
      end

      private
        def series(entries, variant)
          rows = entries.map { |entry| entry.row(variant) }
          lows = rows.map { |row| self.class.seat_percentile(row.histogram, PERCENTILE_LOW) }
          highs = rows.map { |row| self.class.seat_percentile(row.histogram, PERCENTILE_HIGH) }

          {
            dem: rows.map { |row| row.p_dem.round(4) },
            rep: rows.map { |row| row.p_rep.round(4) },
            dem_labels: rows.map { |row| Site::Format.percent(row.p_dem) },
            rep_labels: rows.map { |row| Site::Format.percent(row.p_rep) },
            seats: rows.map { |row| row.mean_seats.round(2) },
            seats_labels: rows.map { |row| format("%.1f", row.mean_seats) },
            low: lows,
            high: highs,
            range_labels: lows.zip(highs).map { |low, high| "#{low}–#{high}" if low && high }
          }
        end

        def milliseconds(time)
          time.to_i * 1000
        end
    end
  end
end
