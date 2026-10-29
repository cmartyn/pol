require "application_system_test_case"

class PollsterExclusionSystemTest < ApplicationSystemTestCase
  test "the editor excludes a firm and a reader can inspect its archived polls" do
    pollster = pollsters(:beacon_polling)
    visit edit_admin_pollster_path(pollster)
    fill_in "email_address", with: users(:one).email_address
    fill_in "password", with: "password"
    click_button "Sign in"
    assert_text pollster.name

    check "Exclude this pollster"
    fill_in "Reason", with: "The pollster withdrew its results."
    fill_in "Source link (optional)", with: "https://example.com/withdrawal"
    click_button "Save pollster"
    assert_text "Pollster excluded. A forecast update is queued."
    assert_checked_field "Exclude this pollster"
    assert_text "Published dispatches citing this pollster"

    click_link "Public record"
    assert_text "Excluded from the forecast since"
    assert_text "The pollster withdrew its results."
    assert_selector "[data-testid='poll-feed-row']", text: "Beacon Polling"
    page.save_screenshot(Rails.root.join("tmp/screenshots/pollster-exclusion.png"))

    visit polls_path
    assert_no_selector "[data-testid='poll-feed-row']", text: "Beacon Polling"
    visit pollsters_path
    assert_selector "[data-testid='pollster-row']", text: "Cardinal Research"
    assert_no_selector "[data-testid='excluded-pollsters']", text: "Beacon Polling"
    click_link "1 excluded"
    find("[data-testid='excluded-pollsters'] summary").click
    assert_selector "[data-testid='excluded-pollsters']", text: "Beacon Polling"
    click_link "View archived polls"
    assert_selector "[data-testid='pollster-exclusion']", text: "The pollster withdrew its results."

    visit edit_admin_pollster_path(pollster)
    uncheck "Exclude this pollster"
    click_button "Save pollster"
    assert_text "Pollster reinstated. A forecast update is queued."
    visit polls_path
    assert_selector "[data-testid='poll-feed-row']", text: "Beacon Polling"
  end
end
