require "test_helper"

# Reference values from d3-geo 3.x's geoAlbersUsa() at its defaults.
class Site::Maps::ProjectionTest < ActiveSupport::TestCase
  def assert_point(expected, actual)
    assert_in_delta expected[0], actual[0], 1e-9
    assert_in_delta expected[1], actual[1], 1e-9
  end

  test "albers_usa matches d3 for the lower 48" do
    assert_point [ 794.5954450548626, 176.53258338778596 ], Site::Maps::Projection.albers_usa("NY").call(-74.006, 40.7128)
    assert_point [ 159.14774137678137, 37.02484281589295 ], Site::Maps::Projection.albers_usa("WA").call(-122.33, 47.61)
    assert_point [ 755.9622778761034, 470.2325823020949 ], Site::Maps::Projection.albers_usa("FL").call(-80.19, 25.76)
  end

  test "Alaska and Hawaii land in d3's insets, including west of the date line" do
    alaska = Site::Maps::Projection.albers_usa("AK")

    assert_point [ 171.16312940682022, 446.9316317975319 ], alaska.call(-149.9, 61.22)
    assert_point [ 33.78981605127143, 470.4058896087959 ], alaska.call(173.2, 52.9)
    assert_point [ 33.78981605127143, 470.4058896087959 ], alaska.call(173.2 - 360, 52.9)
    assert_point [ 298.44898072875196, 450.9298708116952 ], Site::Maps::Projection.albers_usa("HI").call(-157.86, 21.31)
  end

  test "a fitted conic is centered on the state's middle longitude" do
    rings = [ [ [ -72.0, 41.0 ], [ -70.0, 41.0 ], [ -70.0, 47.0 ], [ -72.0, 47.0 ], [ -72.0, 41.0 ] ] ]
    projection = Site::Maps::Projection.fitted(rings)

    assert_equal [ 42.0, 46.0 ], projection.parallels
    assert_in_delta 0.0, projection.call(-71.0, 44.0).first, 1e-12
    assert_in_delta(-projection.call(-72.0, 44.0).first, projection.call(-70.0, 44.0).first, 1e-12)
  end
end
