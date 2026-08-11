require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "redirects unauthenticated to sign-in" do
    sign_out
    get admin_root_path
    assert_redirected_to new_session_path
  end

  test "renders every card with fixture data" do
    get admin_root_path

    assert_response :success
    assert_select "[data-testid='admin-card-last-scrape']"
    assert_select "[data-testid='admin-card-last-run']"
    assert_select "[data-testid='admin-card-publishing-today']"
    assert_select "[data-testid='admin-card-skips-today']"
    assert_select "[data-testid='admin-card-kill-switch']"
    assert_select "[data-testid='admin-card-quick-links']"
  end

  test "shows the last scrape run's status and counts" do
    get admin_root_path
    assert_select "[data-testid='admin-last-scrape-status']", text: "Succeeded"
  end

  test "shows the last model run's chamber control numbers when succeeded" do
    get admin_root_path
    assert_select "[data-testid='admin-senate-control']", text: "55%"
    assert_select "[data-testid='admin-house-control']", text: "48%"
  end

  test "counts today's published dispatches (ET) and excludes older ones" do
    Dispatch.create!(headline: "Today's brief", body_markdown: "Body.", kind: :daily_brief, status: :published,
                      published_at: Time.current, model_slug: "fixture/writer-model")
    Dispatch.create!(headline: "Two days ago", body_markdown: "Body.", kind: :daily_brief, status: :published,
                      published_at: 2.days.ago, model_slug: "fixture/writer-model")

    get admin_root_path
    assert_select "[data-testid='admin-dispatches-today-count']", text: "1"
  end

  test "groups today's skips by reason" do
    NewsroomSkip.record!(kind: :poll_reaction, reason: :cap_reached, detail: "a")
    NewsroomSkip.record!(kind: :poll_reaction, reason: :cap_reached, detail: "b")
    NewsroomSkip.record!(kind: :daily_brief, reason: :agents_disabled, detail: "c")

    get admin_root_path
    assert_select "[data-testid='admin-skip-reason-row']", count: 2
  end

  test "shows an honest empty state with no skips today" do
    get admin_root_path
    assert_select "[data-testid='admin-skips-today-empty']"
  end

  test "shows the kill switch's effective state" do
    get admin_root_path
    assert_select "[data-testid='admin-kill-switch-effective']", text: "Agents ON"
  end

  test "shows the kill switch as off when the stored value is false" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")
    get admin_root_path
    assert_select "[data-testid='admin-kill-switch-effective']", text: "Agents OFF"
  end
end
