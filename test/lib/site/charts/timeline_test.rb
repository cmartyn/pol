require "test_helper"

class Site::Charts::TimelineTest < ActiveSupport::TestCase
  test "a race with a single succeeded forecast is sparse: one point, no line" do
    payload = Site::Charts::Timeline.build(race: races(:senate_maine))

    assert_equal 1, payload[:points].size
    assert payload[:sparse]
    point = payload[:points].first
    assert_equal forecasts(:maine_forecast).p_dem_win, point[:p_dem_win]
    assert_equal model_runs(:model_run_one).started_at.iso8601, point[:t]
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

  test "a House baseline correction does not label an unchanged Senate timeline" do
    corrected = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: "2026-10-25 10:00:00",
      params_snapshot: { house_baselines: { revision: Forecast::HouseBaselines.current.revision } })
    Forecast.create!(model_run: corrected, race: races(:senate_maine), p_dem_win: 0.62, p_rep_win: 0.38, mean_margin: 3.2)
    payload = Site::Charts::Timeline.build(race: races(:senate_maine))
    assert_equal 2, payload[:points].size
    assert_empty payload[:baseline_corrections]
  end

  test "corrections are dated on the first run after each one" do
    race = Race.create!(office: :house, state: "TN", district: 9, cycle: 2026,
      slug: "house-2026-tn-09", baseline_margin: 45.6, baseline_imputed: true)
    Forecast.create!(race: race, model_run: model_runs(:model_run_one), p_dem_win: 1, p_rep_win: 0, mean_margin: 56.8)
    new_lines = { "revision" => Forecast::HouseBaselines.current.revision }
    rebased = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: "2026-10-25 10:00:00",
      params_snapshot: { "house_baselines" => new_lines })
    repaired = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: "2026-10-26 09:00:00",
      params_snapshot: { "house_baselines" => new_lines, "poll_input_revision" => "candidates-v2" })
    [ rebased, repaired ].each do |run|
      Forecast.create!(race: race, model_run: run, p_dem_win: 0.1, p_rep_win: 0.9, mean_margin: -20.0,
                       effective_poll_weight: 1.2)
    end

    payload = Site::Charts::Timeline.build(race: race)

    assert_equal [ "Oct 25, 2026" ], payload[:baseline_corrections]
    assert_equal [ "Oct 26, 2026" ], payload[:polling_corrections]
    # Both kinds, in time order, for the chart's correction rules.
    assert_equal [ rebased, repaired ].map { |run| run.started_at.iso8601 }, payload[:correction_times]
  end

  # The polling repair of Oct 26 was site-wide, but Wyoming had no poll in
  # its average before it or after it: its line could not have moved for
  # that reason, and a note saying it did was the critique's error.
  test "a polling correction marks only a race with polls on one side of it or the other" do
    race = races(:senate_florida_special)
    before = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: "2026-10-26 08:00:00")
    after = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: "2026-10-26 13:00:00",
      params_snapshot: { "poll_input_revision" => "candidate-results-v2" })
    rows = [ before, after ].map do |run|
      Forecast.create!(race: race, model_run: run, p_dem_win: 0.2, p_rep_win: 0.8, mean_margin: -12.0)
    end

    payload = Site::Charts::Timeline.build(race: race)
    assert_empty payload[:polling_corrections]
    assert_empty payload[:correction_times]

    rows.first.update!(effective_poll_weight: 0.8)
    payload = Site::Charts::Timeline.build(race: race)
    assert_equal [ "Oct 26, 2026" ], payload[:polling_corrections]
    assert_equal [ after.started_at.iso8601 ], payload[:correction_times]
  end

  # By late October a race page charted ~1,250 runs twice over, and the JSON
  # was most of the page. Older runs on the same level as the last kept one
  # are dropped; a step keeps the run before it, so it stays a step.
  test "older runs are thinned to the shape, and the last week keeps every run" do
    race = races(:senate_florida_special)
    latest = Time.zone.parse("2026-10-29 07:00")
    times = (0..240).map { |i| latest - (i * 2).hours }.reverse # ~20 days, two-hourly
    step_at = latest - 15.days
    times.each do |time|
      p_dem = time < step_at ? 0.30 : 0.45
      run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: time)
      Forecast.create!(race: race, model_run: run, p_dem_win: p_dem, p_rep_win: 1 - p_dem, mean_margin: -5.0)
    end

    points = Site::Charts::Timeline.build(race: race)[:points]
    kept = points.map { |point| Time.zone.parse(point[:t]) }

    assert_operator points.size, :<, times.size / 2
    assert_equal times.first, kept.first
    assert_equal times.select { |time| time >= latest - 7.days }, kept.select { |time| time >= latest - 7.days }
    # Both sides of the step, so the line rises where the forecast did.
    first_after = times.find { |time| time >= step_at }
    last_before = times.reverse.find { |time| time < step_at }
    assert_includes kept, first_after
    assert_includes kept, last_before
    # And at least one run a day, so a pointer on any date reads that date.
    assert_equal times.map(&:to_date).uniq, kept.map(&:to_date).uniq
  end

  test "the summary names the leader now and its range over the history" do
    race = races(:senate_florida_special)
    [ [ "2026-08-20 06:00", 0.30 ], [ "2026-09-20 06:00", 0.55 ], [ "2026-10-20 06:00", 0.40 ] ].each do |time, p_dem|
      run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: time)
      Forecast.create!(race: race, model_run: run, p_dem_win: p_dem, p_rep_win: 1 - p_dem, mean_margin: -3.0)
    end

    summary = Site::Charts::Timeline.build(race: race)[:summary]

    assert_equal "Republicans: 60% in the latest run, between 45% and 70% since Aug 20, 2026.", summary[:excl_internals]
  end

  test "the page-only keys stay out of the chart's JSON" do
    html = ApplicationController.render(partial: "races/timeline_chart",
                                        locals: { payload: Site::Charts::Timeline.build(race: races(:senate_maine)) })
    json = Nokogiri::HTML(html).at_css("script[type='application/json']").text

    assert_not_includes JSON.parse(json).keys, "change"
    assert_not_includes JSON.parse(json).keys, "summary"
  end

  # A race page charts every run, and a recent run's snapshot carries every
  # House district's baseline: about 137 KB of JSON, of which the chart
  # needs three revision fields. Loading whole snapshots took 1.2 s per race
  # page in production by late October, and grew with every run.
  test "reads each run's revision fields without loading its whole snapshot" do
    whole_snapshot = /"model_runs"\.(?:\*|"params_snapshot")/

    assert_no_queries_match(whole_snapshot) do
      Site::Charts::Timeline.build(race: races(:senate_maine))
    end
  end

  # The interactive chart's words all come from the payload (the JS only
  # places them): the tooltip's dateline and the whole-percent strings for
  # tooltip rows and on-chart end labels.
  test "each point carries the tooltip dateline and pre-formatted percent labels" do
    payload = Site::Charts::Timeline.build(race: races(:senate_maine))

    point = payload[:points].first
    assert_equal "Aug 1, 2026 · 6:00 AM EDT", point[:time_label]
    # "Other" rides along only when its line is drawn.
    assert_equal({ dem: "62%", rep: "38%" }, point[:pct_labels])
    assert_not point.key?(:p_other_win)
  end

  # Pin the dateline's shape, not just the fixture's instance of it: month
  # day, year · 12-hour clock, zone — and no zero-padding on day or hour
  # (%-d/%-I), which is the detail a strftime edit would silently regress.
  #
  # December also pins the other half of the zone name: unlike the August
  # fixture above this run is on the winter side of DST, so the dateline has
  # to say EST where that one says EDT. Note the bare string is parsed in
  # Time.zone (Eastern) on assignment, so 18:05 here means 6:05 PM Eastern.
  test "time_label keeps the unpadded dateline shape" do
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: "2026-12-09 18:05:00")
    Forecast.create!(model_run: run, race: races(:senate_florida_special),
                      p_dem_win: 0.207, p_rep_win: 0.793, mean_margin: -9.0)

    payload = Site::Charts::Timeline.build(race: races(:senate_florida_special))

    point = payload[:points].first
    assert_equal "Dec 9, 2026 · 6:05 PM EST", point[:time_label]
    assert_match(/\A[A-Z][a-z]{2} \d{1,2}, \d{4} · \d{1,2}:\d{2} [AP]M [A-Z]+\z/, point[:time_label])
    # Whole percents via Site::Format.percent — 0.207 says "21%", never "20.7%".
    assert_equal "21%", point[:pct_labels][:dem]
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
    assert_equal "1%", payload[:points].last[:pct_labels][:other]
  end

  test "the tossup band is exposed as the p_dem_win range that counts as a tossup" do
    payload = Site::Charts::Timeline.build(race: races(:senate_maine))

    tossup_band_pp = Pol::Params.fetch!(:site, :tossup_band_pp)
    assert_in_delta 100.0 - tossup_band_pp, payload[:tossup_low_pct]
    assert_in_delta tossup_band_pp, payload[:tossup_high_pct]
  end

  test "the internals series aligns run-for-run, published points standing in where no internals row exists" do
    old = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 3.days.ago, finished_at: 3.days.ago)
    new_run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.day.ago, finished_at: 1.day.ago)
    Forecast.create!(model_run: old, race: races(:senate_florida_special), p_dem_win: 0.20, p_rep_win: 0.80, mean_margin: -11.0)
    Forecast.create!(model_run: new_run, race: races(:senate_florida_special), p_dem_win: 0.30, p_rep_win: 0.70, mean_margin: -9.0)
    Forecast.create!(model_run: new_run, race: races(:senate_florida_special), variant: :incl_internals,
                     p_dem_win: 0.40, p_rep_win: 0.60, mean_margin: -6.0)

    payload = Site::Charts::Timeline.build(race: races(:senate_florida_special))

    assert_equal payload[:points].size, payload[:incl_points].size
    # The old run wrote no internals row, so its incl point would repeat the
    # published one: it is nil, and the chart reads the published point.
    assert_nil payload[:incl_points].first
    assert_in_delta 0.40, payload[:incl_points].last[:p_dem_win]
    assert_in_delta 0.30, payload[:points].last[:p_dem_win]
  end
end
