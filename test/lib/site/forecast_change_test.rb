require "test_helper"

class Site::ForecastChangeTest < ActiveSupport::TestCase
  LATEST = Time.zone.parse("2026-10-29 07:00")

  # Kansas on Oct 29: R 83% at 6:30 AM, R 52% at 7:00 after a poll landed.
  test "an overnight drop compares with the last run that sat away from now" do
    points = [ point(48, 0.82), point(1, 0.83), point(0.5, 0.83), point(0, 0.52) ]

    change = Site::ForecastChange.call(points)

    assert_equal :down, change.kind
    assert_equal "rep", change.party
    assert_in_delta 0.83, change.probability
    assert_equal LATEST - 30.minutes, change.time
  end

  test "a rise reads as up from the earlier figure" do
    change = Site::ForecastChange.call([ point(72, 0.61), point(0, 0.70) ])

    assert_equal :up, change.kind
    assert_in_delta 0.61, change.probability
  end

  test "a lead that changed hands names the side that led" do
    change = Site::ForecastChange.call([ point(30, 0.42), point(0, 0.52) ])

    assert_equal :flipped, change.kind
    assert_equal "dem", change.party
    assert_in_delta 0.58, change.probability
  end

  # site.movers_floor_pp is 1.5: the dashboard's Movers cut, measured above
  # run-to-run simulation noise.
  test "movement under the Movers floor is steady over the window" do
    points = (1..10).map { |day| point(day * 24, 0.60 + (day.even? ? 0.006 : -0.006)) }.reverse + [ point(0, 0.60) ]

    change = Site::ForecastChange.call(points)

    assert_equal :steady, change.kind
    assert_equal :window, change.since
    assert_equal LATEST - 7.days, change.time
    assert_in_delta 0.594, change.low
    assert_in_delta 0.606, change.high
  end

  test "runs older than the window are never the comparison" do
    change = Site::ForecastChange.call([ point(10 * 24, 0.30), point(24, 0.61), point(0, 0.60) ])

    assert_equal :steady, change.kind
    assert_equal :window, change.since
    assert_equal LATEST - 7.days, change.time
    assert_in_delta 0.61, change.high
  end

  test "a race younger than the window is steady since its first run" do
    change = Site::ForecastChange.call([ point(30, 0.605), point(0, 0.60) ])

    assert_equal :steady, change.kind
    assert_equal :first_run, change.since
    assert_equal LATEST - 30.hours, change.time
  end

  # A jump across a correction is the repair, not voters.
  test "the walk back stops at the newest correction" do
    points = [ point(100, 0.80), point(50, 0.60), point(0, 0.61) ]

    change = Site::ForecastChange.call(points, corrections: [ LATEST - 50.hours ])

    assert_equal :steady, change.kind
    assert_equal :correction, change.since
    assert_equal LATEST - 50.hours, change.time
  end

  test "the first run after a correction says so" do
    change = Site::ForecastChange.call([ point(10, 0.80), point(0, 0.60) ], corrections: [ LATEST ])

    assert_equal :corrected, change.kind
    assert_equal LATEST, change.time
  end

  test "one run has nothing to compare with" do
    assert_nil Site::ForecastChange.call([ point(0, 0.60) ])
    assert_nil Site::ForecastChange.call([])
  end

  private
    def point(hours_ago, rep, dem = 1 - rep)
      Site::ForecastChange::Point.new(time: LATEST - hours_ago.hours,
                                      probabilities: { "dem" => dem, "rep" => rep, "other" => 0.0 })
    end
end
