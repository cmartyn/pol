require "test_helper"

class Admin::PollstersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @pollster = pollsters(:beacon_polling)
    sign_in_as users(:one)
  end

  test "all management endpoints require the editor session" do
    sign_out
    get admin_pollsters_path
    assert_redirected_to new_session_path
    get edit_admin_pollster_path(@pollster)
    assert_redirected_to new_session_path
    patch admin_pollster_path(@pollster), params: { pollster: { excluded: "1", exclusion_reason: "Withdrawn" } }
    assert_redirected_to new_session_path
    assert_not @pollster.reload.excluded?
  end

  test "the editor can find a firm, exclude it, review cited dispatches, and reinstate it" do
    get admin_pollsters_path
    assert_response :success
    assert_select "a[href='#{edit_admin_pollster_path(@pollster)}']", text: @pollster.name

    assert_enqueued_with(job: Forecast::RunJob, args: [ { trigger: :pollster_change } ]) do
      patch admin_pollster_path(@pollster), params: { pollster: {
        excluded: "1", exclusion_reason: "Data withdrawn", exclusion_source_url: "https://example.com/notice"
      } }
    end
    assert_redirected_to edit_admin_pollster_path(@pollster)
    follow_redirect!
    assert_select "input[name='pollster[excluded]'][checked]"
    assert_select "[data-testid='pollster-citing-dispatches'] a", text: dispatches(:maine_poll_reaction).headline
    assert_predicate @pollster.reload, :excluded?

    patch admin_pollster_path(@pollster), params: { pollster: { excluded: "0" } }
    assert_redirected_to edit_admin_pollster_path(@pollster)
    assert_not @pollster.reload.excluded?
  end

  test "an invalid reason leaves the pollster included and explains the error" do
    assert_no_enqueued_jobs do
      patch admin_pollster_path(@pollster), params: { pollster: { excluded: "1", exclusion_reason: "" } }
    end
    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /Exclusion reason can't be blank/
    assert_not @pollster.reload.excluded?
  end
end
