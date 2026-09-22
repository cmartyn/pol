require "test_helper"

class Site::Maps::SenateMapTest < ActiveSupport::TestCase
  setup do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "FL", box: [ -87.6, 24.5, -80.0, 31.0 ])
    create_boundary(state: "VT", box: [ -73.4, 42.7, -71.5, 45.0 ])
  end

  def shapes(payload)
    payload[:groups].sole[:shapes].index_by(&:key)
  end

  test "nil until boundaries exist" do
    Boundary.delete_all

    assert_nil Site::Maps::SenateMap.build
  end

  test "every state is a shape; a state with a race links to it and carries both variants" do
    payload = Site::Maps::SenateMap.build
    maine = shapes(payload)["ME"]

    assert_equal "senate", payload[:key]
    assert payload[:interactive]
    assert_match(/\A0 0 960 \d+\z/, payload[:view_box])
    assert_equal %w[FL ME VT], shapes(payload).keys.sort
    assert_equal races(:senate_maine).slug, maine.slug
    assert_equal Site::Maps::Palette.fill(race: races(:senate_maine), forecast: forecasts(:maine_forecast)), maine.fills[:excl_internals]
    assert_equal maine.fills[:excl_internals], maine.fills[:incl_internals]
    assert_equal "Maine Senate", maine.tips[:excl_internals][:header]
    assert_equal Site::Maps::Palette::NO_FORECAST, shapes(payload)["FL"].fills[:excl_internals]
    assert_nil shapes(payload)["VT"].slug
    assert_nil shapes(payload)["VT"].tips
    assert_equal Site::Maps::Palette::NO_RACE, shapes(payload)["VT"].fills[:excl_internals]
    assert_includes payload[:legend][:swatches].map { |swatch| swatch[:label] }, "No Senate race this year"
  end

  test "an internals row recolors only the internals view" do
    Forecast.create!(model_run: model_runs(:model_run_one), race: races(:senate_maine), variant: :incl_internals,
                     p_dem_win: 0.2, p_rep_win: 0.8, p_other_win: 0.0, mean_margin: -6.0)
    maine = shapes(Site::Maps::SenateMap.build)["ME"]

    assert_equal Site::Maps::Palette.shade("rep", 0.8), maine.fills[:incl_internals]
    assert_equal "80%", maine.tips[:incl_internals][:rows].first[:value]
    assert_equal "62%", maine.tips[:excl_internals][:rows].first[:value]
  end

  test "a state with two races is filled by the closer one and names the other" do
    special = Race.create!(office: :senate, state: "ME", cycle: 2026, special: true, slug: "senate-me-2026-special-map-test", lean: 0.0)
    Forecast.create!(model_run: model_runs(:model_run_one), race: special, p_dem_win: 0.05, p_rep_win: 0.95, p_other_win: 0.0, mean_margin: -20.0)
    maine = shapes(Site::Maps::SenateMap.build)["ME"]

    assert_equal races(:senate_maine).slug, maine.slug
    assert_equal "Also on the ballot: Maine Senate (special)", maine.tips[:excl_internals][:footer]
  end

  test "the locator colors only the highlighted state and is not interactive" do
    payload = Site::Maps::SenateMap.build(highlight: races(:senate_maine))

    assert_equal "senate-locator", payload[:key]
    assert_not payload[:interactive]
    assert_nil payload[:legend]
    assert_equal Site::Maps::Palette::NO_RACE, shapes(payload)["FL"].fills[:excl_internals]
    assert_equal Site::Maps::Palette.fill(race: races(:senate_maine), forecast: forecasts(:maine_forecast)), shapes(payload)["ME"].fills[:excl_internals]
    assert shapes(payload).values.all? { |shape| shape.slug.nil? && shape.tips.nil? }
    assert_equal shapes(payload)["ME"].d, payload[:groups].sole[:highlight_d]
  end
end
