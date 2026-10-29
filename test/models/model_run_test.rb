require "test_helper"

class ModelRunTest < ActiveSupport::TestCase
  test "polling repairs invalidate movement comparisons and queued forecast claims" do
    old = model_runs(:model_run_one)
    corrected = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: old.started_at + 7.days,
      params_snapshot: old.params_snapshot.merge("poll_input_revision" => Ingest::Nyt::Mapper::REVISION))

    assert_nil ModelRun.comparison_run(corrected, window_days: 7)
    assert old.poll_inputs_superseded?
    assert old.forecast_inputs_superseded?
    refute old.baseline_superseded?
    refute corrected.forecast_inputs_superseded?
  end

  test "movement comparisons never cross a baseline correction" do
    old = model_runs(:model_run_one)
    corrected = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: old.started_at + 7.days,
      params_snapshot: { house_baselines: { revision: Forecast::HouseBaselines.current.revision } })
    assert_nil ModelRun.comparison_run(corrected, window_days: 7)
    assert old.baseline_superseded?
    assert_not corrected.baseline_superseded?
    later = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: corrected.started_at + 1.day,
      params_snapshot: corrected.params_snapshot)
    assert_equal corrected, ModelRun.comparison_run(later, window_days: 7)
  end

  test "movement comparisons do not cross a change in excluded pollsters" do
    latest = model_runs(:model_run_one)
    latest.update!(params_snapshot: { "excluded_pollsters" => [ { "id" => pollsters(:beacon_polling).id } ] })
    ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 7.days.before(latest.started_at))
    assert_nil ModelRun.comparison_run(latest, window_days: 7)

    comparable = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.day.before(latest.started_at), params_snapshot: latest.params_snapshot)
    assert_equal comparable, ModelRun.comparison_run(latest, window_days: 7)
  end

  # The chamber history chart labels a correction by what changed, and shows
  # a House-only baseline fix on the House chart alone. Each kind is read
  # independently, so a run that changed two inputs at once names both.
  test "input_changes_from names each input that differs between two runs" do
    base = ModelRun.new(params_snapshot: {})
    polls = ModelRun.new(params_snapshot: { "poll_input_revision" => "candidates-v2" })
    baselines = ModelRun.new(params_snapshot: { "house_baselines" => { "revision" => "pres-2024-lines-v1" } })
    excluded = ModelRun.new(params_snapshot: { "excluded_pollsters" => [ { "id" => 7 } ] })
    both = ModelRun.new(params_snapshot: { "poll_input_revision" => "candidates-v2", "excluded_pollsters" => [ { "id" => 7 } ] })

    assert_equal [], base.input_changes_from(ModelRun.new(params_snapshot: {}))
    assert_equal [ :poll_inputs ], polls.input_changes_from(base)
    assert_equal [ :house_baselines ], baselines.input_changes_from(base)
    assert_equal [ :pollster_exclusions ], excluded.input_changes_from(base)
    assert_equal [ :pollster_exclusions, :poll_inputs ], both.input_changes_from(base)
    assert base.comparable_inputs?(ModelRun.new(params_snapshot: {}))
    refute polls.comparable_inputs?(base)
  end

  # Recent snapshots carry every district's baseline (~137 KB of JSON per
  # run in production), so a history of 1,200 runs must not load them. The
  # slim scope keeps only what the input readers need, and they read the
  # same answers from it as from the full record.
  test "with_input_revisions_only reads the same revisions without the rest of the snapshot" do
    run = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: "2026-10-26 09:00:00",
      params_snapshot: {
        "simulation" => { "n_sims" => 100_000 },
        "poll_input_revision" => "candidates-v2",
        "excluded_pollsters" => [ { "id" => 9, "name" => "Example Research" }, { "id" => 4, "name" => "Other" } ],
        "house_baselines" => { "revision" => "pres-2024-lines-v1", "races" => { "36" => { "margin" => 4.2 } } }
      })
    legacy = model_runs(:model_run_one)

    slim = ModelRun.with_input_revisions_only.where(id: [ run.id, legacy.id ]).index_by(&:id)

    assert_equal "candidates-v2", slim[run.id].poll_input_revision
    assert_equal "pres-2024-lines-v1", slim[run.id].baseline_revision
    assert_equal [ 4, 9 ], slim[run.id].excluded_pollster_ids
    assert_equal run.started_at, slim[run.id].started_at
    assert_nil slim[run.id].params_snapshot.dig("house_baselines", "races")
    assert_nil slim[run.id].params_snapshot["simulation"]
    # A snapshot from before any of the three existed reads its defaults.
    assert_equal legacy.poll_input_revision, slim[legacy.id].poll_input_revision
    assert_equal legacy.baseline_revision, slim[legacy.id].baseline_revision
    assert_equal [], slim[legacy.id].excluded_pollster_ids
  end

  test "status enum round-trips every value" do
    ModelRun.statuses.each_key do |value|
      run = ModelRun.new(status: value)
      assert_equal value, run.status
    end
  end

  test "trigger enum round-trips every value" do
    ModelRun.triggers.each_key do |value|
      run = ModelRun.new(trigger: value)
      assert_equal value, run.trigger
    end
  end

  test "n_sims reads the run's own snapshot, not the current parameter" do
    run = model_runs(:model_run_one)

    with_params(simulation: { n_sims: 999_999 }) do
      assert_equal 10_000, run.n_sims,
                   "a forecast drawn at 10,000 must not be relabelled when the parameter moves"
    end
  end

  test "n_sims falls back to the current parameter when the snapshot predates it" do
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: "2026-07-01 00:00:00",
                           params_snapshot: { "averaging" => { "half_life_days" => 14 } })

    assert_equal Pol::Params.fetch!(:simulation, :n_sims), run.n_sims
  end

  test "n_sims falls back when there is no snapshot at all" do
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: "2026-07-01 00:00:00")

    assert_equal Pol::Params.fetch!(:simulation, :n_sims), run.n_sims
  end

  test "succeeded scope returns only succeeded runs" do
    failed_run = ModelRun.create!(status: :failed, trigger: :manual, started_at: "2026-07-01 00:00:00")

    assert_includes ModelRun.succeeded, model_runs(:model_run_one)
    assert_not_includes ModelRun.succeeded, failed_run
  end

  test "latest orders by started_at descending" do
    older_run = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: "2026-06-01 00:00:00")

    ordered = ModelRun.where(id: [ older_run.id, model_runs(:model_run_one).id ]).latest
    assert_equal [ model_runs(:model_run_one), older_run ], ordered.to_a
  end

  test "can be created as running with no finished_at yet" do
    run = ModelRun.create!(status: :running, trigger: :cron, started_at: Time.current)
    assert_nil run.finished_at
  end

  test "succeeded.latest excludes failed runs and orders succeeded ones by started_at" do
    older_succeeded = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: "2026-06-01 00:00:00")
    newer_failed = ModelRun.create!(status: :failed, trigger: :manual, started_at: "2026-08-09 00:00:00")

    ordered = ModelRun.where(id: [ older_succeeded.id, newer_failed.id, model_runs(:model_run_one).id ])
      .succeeded.latest

    assert_equal [ model_runs(:model_run_one), older_succeeded ], ordered.to_a
  end

  # The one answer to "what did this look like last week", shared by the
  # dashboard's movers module and the newsroom's movement notes.
  test "comparison_run picks the succeeded run closest to the window, in either direction" do
    latest = model_runs(:model_run_one)
    yesterday = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.day.before(latest.started_at))
    six_days = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 6.days.before(latest.started_at))
    ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 40.days.before(latest.started_at))

    assert_equal six_days, ModelRun.comparison_run(latest, window_days: 7)
    assert_equal yesterday, ModelRun.comparison_run(latest, window_days: 0)
  end

  test "comparison_run ignores failed and running runs, and is nil with no history" do
    latest = model_runs(:model_run_one)
    ModelRun.create!(status: :failed, trigger: :cron, started_at: 7.days.before(latest.started_at))
    ModelRun.create!(status: :running, trigger: :cron, started_at: 7.days.before(latest.started_at))

    assert_nil ModelRun.comparison_run(latest, window_days: 7)
  end

  test "previous_succeeded is the run immediately before, never the run itself or a later one" do
    latest = model_runs(:model_run_one)
    just_before = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.hour.before(latest.started_at))
    ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 3.days.before(latest.started_at))
    ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.hour.after(latest.started_at))

    assert_equal just_before, ModelRun.previous_succeeded(latest)
    assert_nil ModelRun.previous_succeeded(ModelRun.succeeded.order(:started_at).first)
  end
end
