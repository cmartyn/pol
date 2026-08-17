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

  # The caveat has been reworded twice and the marker has outlived both: Phase
  # 3's "model likely overstates certainty", then a count of 538's components.
  # What has to survive every rewrite is that the House figure never appears
  # without saying it is a little too confident.
  #
  # Pinning the omission and the consequence rather than the sentence, because
  # the sentence is the part that keeps changing — and asserting the two
  # retired phrasings are gone, since the failure mode here is old copy
  # surviving a rewrite somewhere else on the page.
  test "the House control probability always carries its error-model note" do
    get root_path
    assert_select "[data-testid='chamber-card-house'] [data-testid='house-error-note']" do
      assert_select "*", text: /leaves out one correlated term/
      assert_select "*", text: /firmer than it should be/
    end
    refute_match(/overstates certainty/, response.body)
    # The dashboard must not imply this model is an unfinished copy of 538's.
    # That claim belongs on the methodology page, where it is sourced and
    # states a difference rather than a shortfall against a target.
    refute_match(/four of the five correlated error components/, response.body)
    # The Senate card needs no such note: the omitted component is a
    # district-level correlation and 35 races feel it far less than 435.
    assert_select "[data-testid='chamber-card-senate'] [data-testid='house-error-note']", count: 0
  end

  test "shows the national environment as a formatted margin" do
    get root_path
    assert_select "[data-testid='national-environment']"
  end

  # Regression guard for the bug where this surface built its Averager with
  # no house_effects lookup at all, publishing the unadjusted average while
  # every forecast displayed beside it was built from the adjusted one.
  test "the national environment is the house-effects-adjusted average, not the raw one" do
    HouseEffect.create!(model_run: model_runs(:model_run_one), pollster: pollsters(:delta_metrics),
                        effect_raw: 1.0, effect_shrunk: 1.0, residual_count: 5, applied: true)

    get root_path

    # Unadjusted, the fixture world's lone generic-ballot poll averages to
    # D+2.0 (see Newsroom::ContextTest) — the applied +1.0 effect must come
    # off it here exactly as it does everywhere else the average is printed.
    assert_select "[data-testid='national-environment']" do
      assert_select "*", text: "D+1.0"
    end
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
