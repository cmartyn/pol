require "test_helper"

class ModelRunTest < ActiveSupport::TestCase
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
end
