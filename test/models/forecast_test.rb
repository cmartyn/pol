require "test_helper"

class ForecastTest < ActiveSupport::TestCase
  test "latest_for_races returns only rows from the most recently succeeded model run" do
    older_run = ModelRun.create!(
      status: :succeeded, trigger: :cron,
      started_at: "2026-06-01 06:00:00", finished_at: "2026-06-01 06:05:00"
    )
    older_forecast = Forecast.create!(
      model_run: older_run, race: races(:senate_maine),
      p_dem_win: 0.99, p_rep_win: 0.01, mean_margin: 40.0
    )

    latest = Forecast.latest_for_races

    assert_includes latest, forecasts(:maine_forecast)
    assert_not_includes latest, older_forecast
  end

  test "latest_for_races excludes forecasts from a newer but not-yet-succeeded run" do
    newer_running_run = ModelRun.create!(status: :running, trigger: :cron, started_at: "2026-08-05 06:00:00")
    newer_forecast = Forecast.create!(
      model_run: newer_running_run, race: races(:senate_maine),
      p_dem_win: 0.5, p_rep_win: 0.5, mean_margin: 0.0
    )

    latest = Forecast.latest_for_races

    assert_includes latest, forecasts(:maine_forecast)
    assert_not_includes latest, newer_forecast
  end

  test "unique index prevents two forecasts for the same model_run and race" do
    duplicate = Forecast.new(
      model_run: model_runs(:model_run_one), race: races(:senate_maine),
      p_dem_win: 0.5, p_rep_win: 0.5, mean_margin: 0.0
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) do
        duplicate.save(validate: false)
      end
    end
  end

  test "by_competitiveness orders the closest-to-a-coin-flip races first" do
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.hour.ago)
    tossup = Forecast.create!(model_run: run, race: races(:senate_maine), p_dem_win: 0.52, p_rep_win: 0.48, mean_margin: 0.4)
    lean = Forecast.create!(model_run: run, race: races(:house_ny_17), p_dem_win: 0.70, p_rep_win: 0.30, mean_margin: 5.0)
    safe = Forecast.create!(model_run: run, race: races(:senate_florida_special), p_dem_win: 0.95, p_rep_win: 0.05, mean_margin: 20.0)

    ordered = Forecast.where(model_run: run).by_competitiveness

    assert_equal [ tossup, lean, safe ], ordered.to_a
  end
end
