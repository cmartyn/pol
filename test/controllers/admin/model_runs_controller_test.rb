require "test_helper"

class Admin::ModelRunsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "index lists model runs" do
    get admin_model_runs_path
    assert_response :success
    assert_select "[data-testid='admin-model-run-row']", count: ModelRun.count
  end

  test "show renders the pretty params snapshot" do
    get admin_model_run_path(model_runs(:model_run_one))
    assert_response :success
    assert_select "[data-testid='admin-model-run-snapshot']", text: /n_sims/
  end

  test "show says there's no earlier run to compare against when there isn't one" do
    get admin_model_run_path(model_runs(:model_run_one))
    assert_select "[data-testid='admin-params-diff-empty']"
  end

  test "show renders an added/changed/removed diff against the previous succeeded run" do
    previous = ModelRun.create!(
      status: :succeeded, trigger: :cron, started_at: model_runs(:model_run_one).started_at - 1.day,
      params_snapshot: { "n_sims" => 5_000, "half_life_days" => 14, "old_only_key" => "x" }
    )
    current = ModelRun.create!(
      status: :succeeded, trigger: :cron, started_at: model_runs(:model_run_one).started_at,
      params_snapshot: { "n_sims" => 10_000, "half_life_days" => 14, "new_only_key" => "y" }
    )

    get admin_model_run_path(current)

    assert_select "[data-testid='admin-params-diff-row']", count: 3
    assert_select "[data-testid='admin-params-diff-table']", text: /n_sims/
    assert_select "[data-testid='admin-params-diff-table']", text: /old_only_key/
    assert_select "[data-testid='admin-params-diff-table']", text: /new_only_key/
    assert_select "[data-testid='admin-params-diff-table']", text: /half_life_days/, count: 0
    assert_equal previous, ModelRun.previous_succeeded(current)
  end

  test "show renders an honest error message for a failed run" do
    failed = ModelRun.create!(status: :failed, trigger: :manual, started_at: Time.current, error_message: "boom")
    get admin_model_run_path(failed)
    assert_select "[data-testid='admin-model-run-error']", text: "boom"
  end

  test "create enqueues Forecast::RunJob with trigger manual and redirects with a flash" do
    assert_enqueued_with(job: Forecast::RunJob, args: [ { trigger: :manual } ], queue: "default") do
      post admin_model_runs_path
    end

    assert_redirected_to admin_model_runs_path
    follow_redirect!
    assert_select "[data-testid='admin-flash-notice']", text: /enqueued/i
  end
end
