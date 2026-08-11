require "test_helper"

class Admin::NewsroomSkipsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "index lists skips with detail text" do
    NewsroomSkip.record!(kind: :poll_reaction, race: races(:senate_maine), reason: :cap_reached, detail: "three already today")

    get admin_newsroom_skips_path

    assert_response :success
    assert_select "[data-testid='admin-skip-row']", text: /three already today/
  end

  test "index filters by reason and kind" do
    NewsroomSkip.record!(kind: :poll_reaction, reason: :cap_reached, detail: "a")
    NewsroomSkip.record!(kind: :daily_brief, reason: :agents_disabled, detail: "b")

    get admin_newsroom_skips_path, params: { reason: "cap_reached" }
    assert_select "[data-testid='admin-skip-row']", count: NewsroomSkip.where(reason: :cap_reached).count

    get admin_newsroom_skips_path, params: { kind: "daily_brief" }
    assert_select "[data-testid='admin-skip-row']", count: NewsroomSkip.where(kind: :daily_brief).count
  end

  test "groups today's skips by reason in the header, excluding older ones" do
    NewsroomSkip.record!(kind: :poll_reaction, reason: :cap_reached, detail: "today one")
    NewsroomSkip.record!(kind: :poll_reaction, reason: :cap_reached, detail: "today two")
    NewsroomSkip.create!(kind: :poll_reaction, reason: :cap_reached, detail: "old", created_at: 2.days.ago)

    get admin_newsroom_skips_path

    assert_select "[data-testid='admin-skip-today-reason-count']", text: /Cap reached: 2/
  end

  test "shows an honest empty state with no skips today" do
    get admin_newsroom_skips_path
    assert_select "[data-testid='admin-skips-today-empty']"
  end
end
