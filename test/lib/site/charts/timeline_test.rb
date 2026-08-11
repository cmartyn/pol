require "test_helper"

class Site::Charts::TimelineTest < ActiveSupport::TestCase
  test "a race with a single succeeded forecast is sparse: one point, no line" do
    payload = Site::Charts::Timeline.build(race: races(:senate_maine))

    assert_equal 1, payload[:points].size
    assert payload[:sparse]
    point = payload[:points].first
    assert_equal forecasts(:maine_forecast).p_dem_win, point[:p_dem_win]
    assert_equal model_runs(:model_run_one).started_at.iso8601, point[:t]
    assert_equal model_runs(:model_run_one).started_at.strftime("%b %-d"), point[:label]
  end

  test "a race with no succeeded forecast at all gets an empty, still-valid payload" do
    payload = Site::Charts::Timeline.build(race: races(:senate_florida_special))

    assert_equal [], payload[:points]
    assert payload[:sparse]
  end

  test "points are ordered oldest first across multiple succeeded runs" do
    older = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: "2026-07-01 06:00:00")
    newer = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: "2026-08-15 06:00:00")
    Forecast.create!(model_run: older, race: races(:senate_florida_special), p_dem_win: 0.20, p_rep_win: 0.80, mean_margin: -11.0)
    Forecast.create!(model_run: newer, race: races(:senate_florida_special), p_dem_win: 0.30, p_rep_win: 0.70, mean_margin: -9.0)

    payload = Site::Charts::Timeline.build(race: races(:senate_florida_special))

    assert_equal 2, payload[:points].size
    assert_not payload[:sparse]
    assert_equal [ 0.20, 0.30 ], payload[:points].map { |p| p[:p_dem_win] }
  end

  test "excludes forecasts from a run that has not succeeded" do
    running = ModelRun.create!(status: :running, trigger: :cron, started_at: "2026-08-20 06:00:00")
    Forecast.create!(model_run: running, race: races(:senate_florida_special), p_dem_win: 0.99, p_rep_win: 0.01, mean_margin: 30.0)

    payload = Site::Charts::Timeline.build(race: races(:senate_florida_special))

    assert_equal [], payload[:points]
  end

  test "show_other is false when no point has a meaningful non-major-party probability" do
    payload = Site::Charts::Timeline.build(race: races(:senate_maine))
    assert_not payload[:show_other]
  end

  test "show_other turns on when a point's p_other_win is visible (>= 1%)" do
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: "2026-08-20 06:00:00")
    Forecast.create!(model_run: run, race: races(:senate_florida_special),
                      p_dem_win: 0.20, p_rep_win: 0.79, p_other_win: 0.01, mean_margin: -9.0)

    payload = Site::Charts::Timeline.build(race: races(:senate_florida_special))

    assert payload[:show_other]
  end

  test "the tossup band is exposed as the p_dem_win range that counts as a tossup" do
    payload = Site::Charts::Timeline.build(race: races(:senate_maine))

    tossup_band_pp = Pol::Params.fetch!(:site, :tossup_band_pp)
    assert_in_delta 100.0 - tossup_band_pp, payload[:tossup_low_pct]
    assert_in_delta tossup_band_pp, payload[:tossup_high_pct]
  end
end
