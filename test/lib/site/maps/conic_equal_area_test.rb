require "test_helper"

# Reference values from d3-geo 3.x (geoConicEqualArea), computed once outside
# the repository; the port must agree to 1e-9.
class Site::Maps::ConicEqualAreaTest < ActiveSupport::TestCase
  def assert_point(expected, actual)
    assert_in_delta expected[0], actual[0], 1e-9
    assert_in_delta expected[1], actual[1], 1e-9
  end

  test "a unit-scale conic matches d3" do
    projection = Site::Maps::ConicEqualArea.new(parallels: [ 40, 45 ], rotate: 72)

    assert_point [ 0.012111169299657693, -0.6931700789856656 ], projection.call(-71.06, 42.36)
    assert_point [ -0.019745469143738033, -0.6695216254861878 ], projection.call(-73.5, 41.0)
    assert_equal [ 40, 45 ], projection.parallels
  end

  test "parallels symmetric about the equator are refused" do
    assert_raises(ArgumentError) { Site::Maps::ConicEqualArea.new(parallels: [ -10, 10 ], rotate: 0) }
  end
end
