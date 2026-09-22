require "test_helper"

class Site::Maps::HouseMapTest < ActiveSupport::TestCase
  setup do
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])
    create_boundary(state: "NY", district: 18, box: [ -74.9, 41.2, -74.2, 41.9 ])
    create_boundary(state: "VT", box: [ -73.4, 42.7, -71.5, 45.0 ])
  end

  test "one clipped group per state that has districts" do
    payload = Site::Maps::HouseMap.build
    group = payload[:groups].sole

    assert_equal "house", payload[:key]
    assert_equal "NY", group[:state]
    assert_equal "house-clip-NY", group[:clip_id]
    assert_equal "house-outline-NY", group[:outline_id]
    assert group[:outline_d].start_with?("M")
    assert_equal %w[NY-17 NY-18], group[:shapes].map(&:key)
    assert_nil group[:highlight_d]
  end

  test "a district with a race links to it; one without is filled as no race" do
    shapes = Site::Maps::HouseMap.build[:groups].sole[:shapes].index_by(&:key)

    assert_equal races(:house_ny_17).slug, shapes["NY-17"].slug
    assert_equal Site::Maps::Palette::NO_FORECAST, shapes["NY-17"].fills[:excl_internals]
    assert_equal "NY-17", shapes["NY-17"].tips[:excl_internals][:header]
    assert_nil shapes["NY-18"].slug
    assert_equal Site::Maps::Palette::NO_RACE, shapes["NY-18"].fills[:incl_internals]
  end

  test "races without a boundary are simply not drawn" do
    Race.create!(office: :house, state: "ZZ", district: 1, cycle: 2026, slug: "house-zz-1-map-test", baseline_margin: 1.0)

    assert_equal %w[NY-17 NY-18], Site::Maps::HouseMap.build[:groups].flat_map { |group| group[:shapes] }.map(&:key)
  end

  test "the key prefixes every SVG id so two maps can share a page" do
    group = Site::Maps::HouseMap.build(key: "dashboard-house", tolerance: 1.0)[:groups].sole

    assert_equal "dashboard-house-clip-NY", group[:clip_id]
  end

  test "nil until boundaries exist" do
    Boundary.delete_all

    assert_nil Site::Maps::HouseMap.build
  end
end
