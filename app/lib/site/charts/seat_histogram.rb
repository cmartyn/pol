# Turns a ChamberForecast's seat_histogram — seat-count => simulation count,
# already binned by Forecast::Simulator — into the small set of domain values
# the seat-histogram partial needs: each bin's probability share, sorted by
# seat count, whether that bin meets the Democratic-control threshold, and
# every human-readable string the chart shows (bin share/seats/control
# labels, axis tick seats, the majority line's label). The words are built
# here, in tested Ruby, so the Stimulus layer only ever positions strings it
# was handed — never composes them. No pixels here (the partial does the
# seats/probability -> SVG-rect arithmetic) and no re-simulation — this only
# reshapes numbers the engine already wrote.
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
      Bin = Struct.new(:seats, :count, :probability, :meets_dem_threshold,
                       :share_label, :seats_label, :control_label, keyword_init: true)

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
          probability = total.zero? ? 0.0 : count.to_f / total
          meets = seats_i >= threshold
          Bin.new(
            seats: seats_i,
            count: count,
            probability: probability,
            meets_dem_threshold: meets,
            share_label: share_label(probability),
            seats_label: "#{seats_i} Dem-caucus #{'seat'.pluralize(seats_i)}",
            control_label: control_label(meets)
          )
        end.sort_by(&:seats)

        {
          chamber: @chamber_forecast.chamber,
          bins: bins,
          dem_threshold: threshold,
          majority_label: "#{threshold} = majority",
          tick_seats: tick_seats(bins),
          mean_dem_seats: @chamber_forecast.mean_dem_seats,
          p_dem_control: @chamber_forecast.p_dem_control,
          p_rep_control: @chamber_forecast.p_rep_control,
          max_probability: bins.map(&:probability).max || 0.0
        }
      end

      private
        # One decimal, floored at "<0.1%". Bin shares are not win
        # probabilities, so the site's whole-percent rule (Site::Format
        # .percent) doesn't apply here — and a bin the simulator actually
        # produced printing "0%" would deny it exists.
        def share_label(probability)
          label = format("%.1f%%", probability * 100)
          probability.positive? && label == "0.0%" ? "<0.1%" : label
        end

        # House seats are complementary (see the header comment: dem < 218
        # always implies rep >= 218), so a below-threshold House bin honestly
        # reads "Rep majority". A below-threshold Senate bin may instead
        # leave an uncommitted independent holding the balance, so its label
        # claims only what the bin supports — never Republican control.
        def control_label(meets_dem_threshold)
          if @chamber_forecast.chamber == "house"
            meets_dem_threshold ? "Dem majority" : "Rep majority"
          else
            meets_dem_threshold ? "Dem control" : "short of Dem control"
          end
        end

        # Clean seat numbers for the partial's HTML axis: multiples of a step
        # picked from the bin range, so a ~20-seat Senate strip ticks every 5
        # and a ~145-seat House strip every 20 without crowding either.
        def tick_seats(bins)
          return [] if bins.empty?

          low = bins.first.seats
          high = bins.last.seats
          step = tick_step(high - low)
          first_tick = (low.to_f / step).ceil * step
          first_tick.step(high, step).to_a
        end

        def tick_step(seat_range)
          case seat_range
          when ..30 then 5
          when ..80 then 10
          when ..160 then 20
          else 25
          end
        end

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
