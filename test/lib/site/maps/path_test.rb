require "test_helper"

class Site::Maps::PathTest < ActiveSupport::TestCase
  test "simplify keeps a real feature and drops points within tolerance of it" do
    spike = [ [ 0, 0 ], [ 1, 1.55 ], [ 2, 3 ], [ 3, 1.45 ], [ 4, 0 ] ]

    assert_equal [ [ 0, 0 ], [ 2, 3 ], [ 4, 0 ] ], Site::Maps::Path.simplify(spike, 0.5)
  end

  test "simplify flattens noise below tolerance" do
    noisy = [ [ 0, 0 ], [ 1, 0.1 ], [ 2, -0.1 ], [ 3, 0.2 ], [ 4, 0 ] ]

    assert_equal [ [ 0, 0 ], [ 4, 0 ] ], Site::Maps::Path.simplify(noisy, 0.5)
  end

  test "simplify handles a closed ring" do
    square = [ [ 0, 0 ], [ 5, 0 ], [ 10, 0 ], [ 10, 10 ], [ 0, 10 ], [ 0, 0 ] ]

    assert_equal [ [ 0, 0 ], [ 10, 0 ], [ 10, 10 ], [ 0, 10 ], [ 0, 0 ] ], Site::Maps::Path.simplify(square, 0.5)
  end

  test "encode writes relative one-decimal paths from rounded absolutes" do
    ring = [ [ 0.04, 0.04 ], [ 10.0, 0.0 ], [ 10.0, 10.26 ], [ 0.0, 10.0 ], [ 0.04, 0.04 ] ]

    assert_equal "M0,0l10,0l0,10.3l-10,-.3z", Site::Maps::Path.encode([ ring ])
  end

  test "encode drops repeated points and joins rings" do
    first = [ [ 0, 0 ], [ 0.01, 0.01 ], [ 1, 0 ], [ 1, 1 ], [ 0, 0 ] ]
    second = [ [ 5, 5 ], [ 6, 5 ], [ 6, 6 ], [ 5, 5 ] ]

    assert_equal "M0,0l1,0l0,1zM5,5l1,0l0,1z", Site::Maps::Path.encode([ first, second ])
  end

  test "number formats tenths compactly" do
    assert_equal %w[0 .5 -.5 12.3 12 -12 -123.4], [ 0, 5, -5, 123, 120, -120, -1234 ].map { |tenths| Site::Maps::Path.number(tenths) }
  end

  test "centroid is the area-weighted center of the largest ring" do
    small = [ [ 100, 100 ], [ 101, 100 ], [ 101, 101 ], [ 100, 101 ], [ 100, 100 ] ]
    big = [ [ 0, 0 ], [ 10, 0 ], [ 10, 4 ], [ 0, 4 ], [ 0, 0 ] ]

    x, y = Site::Maps::Path.centroid([ small, big ])
    assert_in_delta 5.0, x, 1e-9
    assert_in_delta 2.0, y, 1e-9
  end
end
