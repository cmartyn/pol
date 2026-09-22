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

  def ring_box(west, south, east, north)
    [ [ west, south ], [ east, south ], [ east, north ], [ west, north ], [ west, south ] ]
  end

  test "inset_rings keeps Hawaii's main islands and drops a Kure Atoll speck" do
    main = ring_box(-160.5, 18.9, -154.8, 22.3)
    kure = ring_box(-178.4, 28.3, -178.3, 28.4)

    assert_equal [ main ], Site::Maps::Projection.inset_rings("HI", [ main, kure ])
  end

  test "inset_rings keeps Alaska's mainland and an Attu-like Aleutian box" do
    mainland = ring_box(-170, 52, -130, 71)
    attu = ring_box(172.5 - 360, 52.7, 173.5 - 360, 53.1)

    assert_equal [ mainland, attu ], Site::Maps::Projection.inset_rings("AK", [ mainland, attu ])
  end

  test "inset_rings keeps a Colorado box for the lower 48" do
    colorado = ring_box(-109.0, 37.0, -102.0, 41.0)

    assert_equal [ colorado ], Site::Maps::Projection.inset_rings("CO", [ colorado ])
  end
end
