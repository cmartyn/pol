require "test_helper"

class Site::Maps::CanvasTest < ActiveSupport::TestCase
  Region = Struct.new(:state, :rings)

  def box(state, west, south, east, north)
    Region.new(state, [ [ [ west, south ], [ east, south ], [ east, north ], [ west, north ], [ west, south ] ] ])
  end

  test "a state canvas fits the outline to the width and keeps its aspect ratio" do
    outline = box("CO", -109.0, 37.0, -102.0, 41.0)
    canvas = Site::Maps::Canvas.state(outline, width: 600, max_height: 480)

    assert_equal 600, canvas.width
    assert_operator canvas.height, :<, 480
    assert_equal "0 0 600 #{canvas.height}", canvas.view_box
    assert_match(/\AM[^M]+z\z/, canvas.path(outline))
  end

  test "a tall state is limited by max_height and centered across the width" do
    outline = box("NH", -72.0, 41.0, -71.0, 45.0)
    canvas = Site::Maps::Canvas.state(outline, width: 600, max_height: 300)

    assert_equal 300, canvas.height
    assert_in_delta 300.0, canvas.centroid(outline).first, 1.0
  end

  test "rings smaller than the tolerance are dropped, but a boundary never vanishes" do
    outline = box("CO", -109.0, 37.0, -102.0, 41.0)
    canvas = Site::Maps::Canvas.state(outline, width: 600, max_height: 480)
    speck = [ [ -105.0, 39.0 ], [ -104.9999, 39.0 ], [ -104.9999, 39.0001 ], [ -105.0, 39.0001 ], [ -105.0, 39.0 ] ]

    assert_equal 1, canvas.path(Region.new("CO", [ outline.rings.first, speck ])).count("M")
    assert_equal 1, canvas.path(Region.new("CO", [ speck ])).count("M")
  end

  test "the national canvas puts Alaska in the inset below and left of Maine" do
    outlines = [
      box("CA", -124.4, 32.5, -114.1, 42.0), box("ME", -71.1, 43.0, -66.9, 47.5),
      box("AK", -170.0, 52.0, -130.0, 71.0), box("HI", -160.3, 18.9, -154.8, 22.3)
    ]
    canvas = Site::Maps::Canvas.national(outlines, width: 960)
    alaska_x, alaska_y = canvas.centroid(outlines[2])
    maine_x, maine_y = canvas.centroid(outlines[1])

    assert_equal 960, canvas.width
    assert_operator alaska_x, :<, maine_x
    assert_operator alaska_y, :>, maine_y
  end

  test "a Hawaii state canvas centers on the main islands, not a Kure speck" do
    main = [ [ -160.5, 18.9 ], [ -154.8, 18.9 ], [ -154.8, 22.3 ], [ -160.5, 22.3 ], [ -160.5, 18.9 ] ]
    kure = [ [ -178.4, 28.3 ], [ -178.3, 28.3 ], [ -178.3, 28.4 ], [ -178.4, 28.4 ], [ -178.4, 28.3 ] ]
    outline = Region.new("HI", [ main, kure ])
    canvas = Site::Maps::Canvas.state(outline, width: 600, max_height: 480)

    assert_in_delta canvas.width / 2.0, canvas.centroid(outline).first, 1.0
  end

  test "a national canvas frames the same with or without a Hawaii Kure speck" do
    base = [
      box("CA", -124.4, 32.5, -114.1, 42.0), box("ME", -71.1, 43.0, -66.9, 47.5),
      box("AK", -170.0, 52.0, -130.0, 71.0)
    ]
    main = [ [ -160.5, 18.9 ], [ -154.8, 18.9 ], [ -154.8, 22.3 ], [ -160.5, 22.3 ], [ -160.5, 18.9 ] ]
    kure = [ [ -178.4, 28.3 ], [ -178.3, 28.3 ], [ -178.3, 28.4 ], [ -178.4, 28.4 ], [ -178.4, 28.3 ] ]
    without = Site::Maps::Canvas.national(base + [ Region.new("HI", [ main ]) ], width: 960)
    with = Site::Maps::Canvas.national(base + [ Region.new("HI", [ main, kure ]) ], width: 960)

    assert_equal without.view_box, with.view_box
  end
end
