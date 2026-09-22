require "test_helper"

class BoundaryTest < ActiveSupport::TestCase
  test "rings passes a Polygon through and flattens a MultiPolygon" do
    assert_equal 1, Boundary.new(geometry: tigerweb_rectangle(-1, -1, 1, 1)).rings.size

    multi = Boundary.new(geometry: {
      "type" => "MultiPolygon",
      "coordinates" => [ tigerweb_rectangle(0, 0, 1, 1)["coordinates"], tigerweb_rectangle(2, 2, 3, 3)["coordinates"] ]
    })
    assert_equal 2, multi.rings.size
    assert_equal [ 2, 2 ], multi.rings.last.first
  end

  test "one outline per state and one row per district" do
    create_boundary(state: "RI", box: [ -71.9, 41.1, -71.1, 42.0 ])
    create_boundary(state: "RI", district: 1, box: [ -71.9, 41.1, -71.5, 42.0 ])

    assert_not Boundary.new(state: "RI", geometry: tigerweb_rectangle(0, 0, 1, 1), source_url: "https://example.com").valid?
    assert_not Boundary.new(state: "RI", district: 1, geometry: tigerweb_rectangle(0, 0, 1, 1), source_url: "https://example.com").valid?
    assert_equal [ "RI" ], Boundary.outlines.pluck(:state)
    assert_equal [ 1 ], Boundary.districts.pluck(:district)
  end

  test "state must be a two-letter code" do
    assert_not Boundary.new(state: "Rhode Island", geometry: tigerweb_rectangle(0, 0, 1, 1), source_url: "https://example.com").valid?
  end
end
