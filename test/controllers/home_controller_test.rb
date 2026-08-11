require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "root renders the dashboard" do
    get root_path
    assert_response :success
    assert_select "h1", text: /2026 midterms forecast/
  end

  test "does not require authentication" do
    get root_path
    assert_response :success
    assert_nil cookies[:session_id]
  end

  test "shows both chamber cards with the fixture world's forecast" do
    get root_path

    assert_select "[data-testid='chamber-card-senate']"
    assert_select "[data-testid='chamber-card-house']"
    assert_select "[data-testid='seat-histogram-senate']"
    assert_select "[data-testid='seat-histogram-house']"
  end

  test "the House control probability always carries its caveat marker" do
    get root_path
    assert_select "[data-testid='chamber-card-house'] [data-testid='house-caveat']"
    # The Senate card needs no such caveat — only House control is
    # structurally overconfident (docs/BUILD_NOTES.md Phase 3 §A4).
    assert_select "[data-testid='chamber-card-senate'] [data-testid='house-caveat']", count: 0
  end

  test "shows the national environment as a formatted margin" do
    get root_path
    assert_select "[data-testid='national-environment']"
  end

  test "omits the Movers section when there's only one succeeded run" do
    get root_path
    assert_select "[data-testid='movers-section']", count: 0
  end

  test "shows the Movers section once there's a second succeeded run to compare against" do
    latest = model_runs(:model_run_one)
    previous = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: latest.started_at - 7.days)
    Forecast.create!(model_run: previous, race: races(:senate_maine), p_dem_win: 0.30, p_rep_win: 0.70, mean_margin: -10.0)

    get root_path

    assert_select "[data-testid='movers-section']"
    assert_select "[data-testid='mover-row']"
  end

  test "shows an honest empty state for dispatches when none are published" do
    Dispatch.delete_all
    get root_path
    assert_select "[data-testid='dispatches-empty']"
  end

  test "shows published dispatches, truncated, with a link to the full feed" do
    get root_path
    assert_select "[data-testid='dashboard-dispatches'] [data-testid='dispatch-card']"
    assert_select "a[href='#{dispatches_path}']"
  end

  test "renders a graceful empty dashboard when no model run has ever succeeded" do
    ModelRun.update_all(status: ModelRun.statuses.fetch("failed"))

    get root_path

    assert_response :success
    assert_select "[data-testid='dashboard-empty']"
    assert_select "[data-testid='chamber-card-senate']", count: 0
  end
end
