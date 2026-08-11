require "test_helper"

class RaceTest < ActiveSupport::TestCase
  test "office enum round-trips every value" do
    Race.offices.each_key do |value|
      race = Race.new(office: value)
      assert_equal value, race.office
    end
  end

  test "Race.senate and Race.house scopes filter by office" do
    assert_includes Race.senate, races(:senate_maine)
    assert_includes Race.senate, races(:senate_florida_special)
    assert_not_includes Race.senate, races(:house_ny_17)

    assert_includes Race.house, races(:house_ny_17)
    assert_not_includes Race.house, races(:senate_maine)
  end

  test "incumbent_party enum round-trips every value with the incumbent_ prefix" do
    Race.incumbent_parties.each_key do |value|
      race = Race.new(incumbent_party: value)
      assert_equal value, race.incumbent_party
      assert race.public_send("incumbent_#{value}?")
    end
  end

  test "uncontested_party enum round-trips every value with the uncontested_ prefix" do
    Race.uncontested_parties.each_key do |value|
      race = Race.new(uncontested_party: value)
      assert_equal value, race.uncontested_party
      assert race.public_send("uncontested_#{value}?")
    end
  end

  test "state must be a 2-letter code" do
    race = Race.new(office: :senate, state: "maine", slug: "senate-xx-2026")
    assert_not race.valid?
    assert_includes race.errors[:state], "must be a 2-letter code"
  end

  test "slug must be present" do
    race = Race.new(office: :senate, state: "ME")
    assert_not race.valid?
    assert_includes race.errors[:slug], "can't be blank"
  end

  test "slug must be unique" do
    race = Race.new(office: :senate, state: "ME", slug: races(:senate_maine).slug)
    assert_not race.valid?
    assert_includes race.errors[:slug], "has already been taken"
  end

  test "district is required for house races" do
    race = Race.new(office: :house, state: "CA", slug: "house-ca-1-2026")
    assert_not race.valid?
    assert_includes race.errors[:district], "can't be blank"
  end

  test "district is not required for senate races" do
    race = Race.new(office: :senate, state: "ME", slug: "senate-me-2026-b")
    assert race.valid?
  end

  test "#name for a Senate race is the full state name plus the office" do
    assert_equal "Maine Senate", races(:senate_maine).name
  end

  test "#name for a House race is state-district" do
    assert_equal "NY-17", races(:house_ny_17).name
  end

  test "special, open_seat, baseline_imputed, and uncontested flags persist" do
    race = Race.create!(
      office: :house, state: "CA", district: 12, slug: "house-ca-12-2026",
      special: true, open_seat: true, baseline_imputed: true,
      uncontested: true, uncontested_party: :dem
    )
    race.reload

    assert race.special?
    assert race.open_seat?
    assert race.baseline_imputed?
    assert race.uncontested?
    assert race.uncontested_dem?
  end

  test "#latest_forecast returns the forecast from the most recently succeeded run" do
    older_run = ModelRun.create!(
      status: :succeeded, trigger: :cron,
      started_at: "2026-06-01 06:00:00", finished_at: "2026-06-01 06:05:00"
    )
    Forecast.create!(
      model_run: older_run, race: races(:senate_maine),
      p_dem_win: 0.99, p_rep_win: 0.01, mean_margin: 40.0
    )

    assert_equal forecasts(:maine_forecast), races(:senate_maine).latest_forecast
  end
end
