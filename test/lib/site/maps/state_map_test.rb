require "test_helper"

class Site::Maps::StateMapTest < ActiveSupport::TestCase
  setup do
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])
    create_boundary(state: "NY", district: 18, box: [ -74.9, 41.2, -74.2, 41.9 ])
  end

  test "the race's own district is outlined and its neighbors stay in the map" do
    payload = Site::Maps::StateMap.build(races(:house_ny_17))
    group = payload[:groups].sole
    shapes = group[:shapes].index_by(&:key)

    assert_equal "state-NY", payload[:key]
    assert payload[:interactive]
    assert payload[:view_box].start_with?("0 0 600 ")
    assert_equal "state-NY-clip", group[:clip_id]
    assert_equal %w[NY-17 NY-18], shapes.keys
    assert_equal shapes["NY-17"].d, group[:highlight_d]
    assert_nil payload[:legend]
  end

  test "nil when the state has no boundaries yet" do
    Boundary.delete_all

    assert_nil Site::Maps::StateMap.build(races(:house_ny_17))
  end
end
