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
  end
end
