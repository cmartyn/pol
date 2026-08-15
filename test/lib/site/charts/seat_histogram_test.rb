require "test_helper"

class Site::Charts::SeatHistogramTest < ActiveSupport::TestCase
  test "reshapes the Senate histogram into sorted bins with probability shares" do
    payload = Site::Charts::SeatHistogram.build(chamber_forecasts(:senate_chamber_forecast))

    assert_equal "senate", payload[:chamber]
    assert_equal [ 50, 51, 52, 53, 54 ], payload[:bins].map(&:seats)
    assert_in_delta 51.2, payload[:mean_dem_seats]
    assert_in_delta 0.55, payload[:p_dem_control]
    assert_in_delta 0.45, payload[:p_rep_control]

    probabilities = payload[:bins].map(&:probability)
    [ 0.12, 0.28, 0.30, 0.18, 0.12 ].each_with_index do |expected, i|
      assert_in_delta expected, probabilities[i], 1e-9
    end
    assert_in_delta 0.30, payload[:max_probability], 1e-9
  end

  # Republican vice president: Republicans control the Senate at a 50-50 tie,
  # so Democrats need 51 — this is what makes 50 fall short and 51 clear it.
  test "Senate bins are shaded by the Democratic-caucus control threshold (51, with a Republican VP)" do
    payload = Site::Charts::SeatHistogram.build(chamber_forecasts(:senate_chamber_forecast))

    assert_equal 51, payload[:dem_threshold]
    by_seats = payload[:bins].index_by(&:seats)
    assert_not by_seats[50].meets_dem_threshold
    assert by_seats[51].meets_dem_threshold
    assert by_seats[54].meets_dem_threshold
  end

  test "reshapes the House histogram, shaded at the 218-seat majority" do
    payload = Site::Charts::SeatHistogram.build(chamber_forecasts(:house_chamber_forecast))

    assert_equal "house", payload[:chamber]
    assert_equal 218, payload[:dem_threshold]
    assert_equal [ 210, 215, 218, 220, 225 ], payload[:bins].map(&:seats)

    by_seats = payload[:bins].index_by(&:seats)
    assert_not by_seats[215].meets_dem_threshold
    assert by_seats[218].meets_dem_threshold
    assert_in_delta 0.35, payload[:max_probability], 1e-9
  end

  test "an empty histogram produces no bins and a zero max, rather than dividing by zero" do
    chamber_forecast = ChamberForecast.new(chamber: :senate, seat_histogram: {})

    payload = Site::Charts::SeatHistogram.build(chamber_forecast)

    assert_equal [], payload[:bins]
    assert_equal 0.0, payload[:max_probability]
    assert_equal [], payload[:tick_seats]
  end

  test "share_label prints each bin's share to one decimal" do
    payload = Site::Charts::SeatHistogram.build(chamber_forecasts(:senate_chamber_forecast))

    by_seats = payload[:bins].index_by(&:seats)
    assert_equal "12.0%", by_seats[50].share_label
    assert_equal "30.0%", by_seats[52].share_label
  end

  # Bin shares are not win probabilities, so the site's whole-percent rule
  # doesn't apply — and a bin the simulator actually produced must never
  # print as "0.0%", which would deny it exists.
  test "share_label floors a positive share that would print 0.0% at <0.1%" do
    chamber_forecast = ChamberForecast.new(chamber: :senate, seat_histogram: { "50" => 1, "51" => 9_999 })

    payload = Site::Charts::SeatHistogram.build(chamber_forecast)

    by_seats = payload[:bins].index_by(&:seats)
    assert_equal "<0.1%", by_seats[50].share_label
    assert_equal "100.0%", by_seats[51].share_label
  end

  test "seats_label counts Dem-caucus seats, pluralized" do
    payload = Site::Charts::SeatHistogram.build(chamber_forecasts(:house_chamber_forecast))
    assert_equal "210 Dem-caucus seats", payload[:bins].first.seats_label

    # One seat is theoretical, but the label must not read "1 seats".
    one_seat = ChamberForecast.new(chamber: :senate, seat_histogram: { "1" => 1, "2" => 1 })
    assert_equal "1 Dem-caucus seat", Site::Charts::SeatHistogram.build(one_seat)[:bins].first.seats_label
  end

  # The House is complementary (below 218 Dem seats IS a Republican
  # majority), but a below-threshold Senate world can leave an uncommitted
  # independent holding the balance — so the Senate wording claims only what
  # the bin supports, and must never say "Rep" anything.
  test "control_label names the Rep majority in the House but only 'short of Dem control' in the Senate" do
    senate = Site::Charts::SeatHistogram.build(chamber_forecasts(:senate_chamber_forecast))
    senate_by_seats = senate[:bins].index_by(&:seats)
    assert_equal "short of Dem control", senate_by_seats[50].control_label
    assert_equal "Dem control", senate_by_seats[51].control_label
    assert senate[:bins].none? { |bin| bin.control_label.include?("Rep") }

    house = Site::Charts::SeatHistogram.build(chamber_forecasts(:house_chamber_forecast))
    house_by_seats = house[:bins].index_by(&:seats)
    assert_equal "Rep majority", house_by_seats[215].control_label
    assert_equal "Dem majority", house_by_seats[218].control_label
  end

  test "tick_seats steps by 5 across a Senate-sized range" do
    chamber_forecast = ChamberForecast.new(chamber: :senate, seat_histogram: (40..61).to_h { |s| [ s.to_s, 1 ] })

    payload = Site::Charts::SeatHistogram.build(chamber_forecast)

    assert_equal [ 40, 45, 50, 55, 60 ], payload[:tick_seats]
  end

  # The step widens with the seat range (<=30 -> 5, <=80 -> 10, <=160 -> 20,
  # else 25) so a House-sized strip never crowds its axis.
  test "tick_seats widens the step as the seat range grows" do
    ticks_for = ->(low, high) do
      forecast = ChamberForecast.new(chamber: :house, seat_histogram: { low.to_s => 1, high.to_s => 1 })
      Site::Charts::SeatHistogram.build(forecast)[:tick_seats]
    end

    assert_equal (190..260).step(10).to_a, ticks_for.call(190, 260) # range  70 -> 10s
    assert_equal (200..320).step(20).to_a, ticks_for.call(181, 325) # range 144 -> 20s
    assert_equal (175..450).step(25).to_a, ticks_for.call(170, 460) # range 290 -> 25s
  end

  test "majority_label states the control threshold for each chamber" do
    assert_equal "51 = majority", Site::Charts::SeatHistogram.build(chamber_forecasts(:senate_chamber_forecast))[:majority_label]
    assert_equal "218 = majority", Site::Charts::SeatHistogram.build(chamber_forecasts(:house_chamber_forecast))[:majority_label]
  end
end
