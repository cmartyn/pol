require "test_helper"

class Site::Maps::PaletteTest < ActiveSupport::TestCase
  FakeRace = Struct.new(:uncontested, :uncontested_party) do
    def uncontested? = uncontested
  end
  FakeForecast = Struct.new(:p_dem_win, :p_rep_win, :p_other_win)

  test "the party hues are charts/theme.js's" do
    theme = Rails.root.join("app/javascript/charts/theme.js").read
    Site::Maps::Palette::PARTY.each_value { |hex| assert_includes theme, hex }
  end

  test "mix blends from white toward the hue" do
    assert_equal "#ffffff", Site::Maps::Palette.mix("#1d4ed8", 0.0)
    assert_equal "#1d4ed8", Site::Maps::Palette.mix("#1d4ed8", 1.0)
    assert_equal "#8ea7ec", Site::Maps::Palette.mix("#1d4ed8", 0.5)
  end

  test "a certain race is the full hue; an even one is the floor tint" do
    assert_equal "#1d4ed8", Site::Maps::Palette.shade("dem", 1.0)
    assert_equal Site::Maps::Palette.mix("#b91c1c", Site::Maps::Palette::FLOOR), Site::Maps::Palette.shade("rep", 0.5)
    assert_equal Site::Maps::Palette.shade("rep", 0.5), Site::Maps::Palette.shade("rep", 0.3)
  end

  test "fill follows the leader, the uncontested party, or the missing forecast" do
    contested = FakeRace.new(false, nil)

    assert_equal Site::Maps::Palette.shade("dem", 0.62), Site::Maps::Palette.fill(race: contested, forecast: FakeForecast.new(0.62, 0.38, 0.0))
    assert_equal Site::Maps::Palette.shade("other", 0.7), Site::Maps::Palette.fill(race: contested, forecast: FakeForecast.new(0.1, 0.2, 0.7))
    assert_equal Site::Maps::Palette::NO_FORECAST, Site::Maps::Palette.fill(race: contested, forecast: nil)
    assert_equal "#b91c1c", Site::Maps::Palette.fill(race: FakeRace.new(true, "rep"), forecast: nil)
    assert_equal "#64748b", Site::Maps::Palette.fill(race: FakeRace.new(true, "ind"), forecast: nil)
  end

  test "the legend states the tossup band from params" do
    legend = Site::Maps::Palette.legend(no_race_label: "No Senate race this year")

    assert_equal %w[Dem Rep], legend[:ramps].map { |ramp| ramp[:label] }
    assert_includes legend[:swatches].map { |swatch| swatch[:label] }, "No Senate race this year"
    assert_includes legend[:caption], "#{Pol::Params.fetch!(:site, :tossup_band_pp).round}%"
  end
end
