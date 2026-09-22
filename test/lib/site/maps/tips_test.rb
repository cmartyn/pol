require "test_helper"

class Site::Maps::TipsTest < ActiveSupport::TestCase
  test "a forecast race lists nonzero chances, highest first, then the margin" do
    tip = Site::Maps::Tips.for(races(:senate_maine), forecasts(:maine_forecast), sides: %w[dem rep])

    assert_equal "Maine Senate", tip[:header]
    assert_equal "Tossup", tip[:subheader]
    assert_equal [
      { value: "62%", label: "Dem", party: "dem", swatch: true },
      { value: "38%", label: "Rep", party: "rep", swatch: true },
      { value: "D+3.2", label: "estimated margin", party: "dem", swatch: false }
    ], tip[:rows]
    assert_not tip.key?(:footer)
  end

  test "no forecast says so and has no rows" do
    tip = Site::Maps::Tips.for(races(:house_ny_17), nil, sides: %w[dem rep])

    assert_equal "No forecast yet", tip[:subheader]
    assert_empty tip[:rows]
  end

  test "an uncontested race says so" do
    race = races(:house_ny_17)
    race.update!(uncontested: true, uncontested_party: :dem)

    assert_equal "Uncontested", Site::Maps::Tips.for(race, nil, sides: %w[dem rep])[:subheader]
  end

  test "an even margin carries no party, and other races go in the footer" do
    forecast = forecasts(:maine_forecast)
    forecast.mean_margin = 0.04
    tip = Site::Maps::Tips.for(races(:senate_maine), forecast, sides: %w[dem rep], also: "Maine Senate (special)")

    assert_nil tip[:rows].last[:party]
    assert_equal "Even", tip[:rows].last[:value]
    assert_equal "Also on the ballot: Maine Senate (special)", tip[:footer]
  end

  test "the internals view falls back to the published row" do
    maine = races(:senate_maine)
    by_variant = Site::Maps::Forecasts.latest_by_variant([ maine.id ])

    assert_equal forecasts(:maine_forecast), by_variant[:excl_internals][maine.id]
    assert_equal forecasts(:maine_forecast), by_variant[:incl_internals][maine.id]
    assert_equal %i[excl_internals incl_internals], Site::Maps::Forecasts::VARIANTS
  end
end
