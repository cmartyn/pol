# Turns a ChamberForecast's seat_histogram — seat-count => simulation count,
# already binned by Forecast::Simulator — into the small set of domain values
# the seat-histogram partial needs: each bin's probability share, sorted by
# seat count, and whether that bin meets the Democratic-control threshold. No
# pixels here (the partial does the seats/probability -> SVG-rect arithmetic)
# and no re-simulation — this only reshapes numbers the engine already wrote.
#
# The histogram tracks *Democratic-caucus seats per simulated world*, one
# number per world. For the House that number is complementary (dem_seats <
# 218 always implies rep_seats >= 218: no independent ever sits in a modelled
# House race), but for the Senate it is not — a world can leave an
# uncommitted independent holding the balance (docs/BUILD_NOTES.md Phase 3
# §6), so "this bin doesn't reach the Democratic threshold" is not the same
# claim as "Republicans control here". Bins are therefore shaded on a single
# axis — meets the Democratic-control threshold, or doesn't — for both
# chambers, rather than inventing a Republican-control reading the Senate
# histogram can't actually support. The precise p_dem_control/p_rep_control
# numbers (which the engine computes correctly even though this 1-D
# histogram can't visualize their split) are shown as text alongside, not
# derived from these bins.
module Site
  module Charts
    class SeatHistogram
      Bin = Struct.new(:seats, :count, :probability, :meets_dem_threshold, keyword_init: true)

      def self.build(chamber_forecast)
        new(chamber_forecast).build
      end

      def initialize(chamber_forecast)
        @chamber_forecast = chamber_forecast
      end

      def build
        histogram = @chamber_forecast.seat_histogram || {}
        total = histogram.values.sum
        threshold = dem_threshold

        bins = histogram.map do |seats, count|
          seats_i = Integer(seats)
          Bin.new(
            seats: seats_i,
            count: count,
            probability: total.zero? ? 0.0 : count.to_f / total,
            meets_dem_threshold: seats_i >= threshold
          )
        end.sort_by(&:seats)

        {
          chamber: @chamber_forecast.chamber,
          bins: bins,
          dem_threshold: threshold,
          mean_dem_seats: @chamber_forecast.mean_dem_seats,
          p_dem_control: @chamber_forecast.p_dem_control,
          p_rep_control: @chamber_forecast.p_rep_control,
          max_probability: bins.map(&:probability).max || 0.0
        }
      end

      private
        # The same threshold Forecast::Simulator uses to call control
        # (#senate_outcome / #house_outcome) — read from params, not
        # re-derived by simulating anything.
        def dem_threshold
          if @chamber_forecast.chamber == "senate"
            total = Pol::Params.fetch!(:chambers, :senate_total_seats)
            tie = total / 2
            Pol::Params.fetch!(:chambers, :vp_party) == "dem" ? tie : tie + 1
          else
            Pol::Params.fetch!(:chambers, :house_majority_seats)
          end
        end
    end
  end
end
