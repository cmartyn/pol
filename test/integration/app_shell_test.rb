require "test_helper"

# Phone and tablet public pages carry the shell. Desktop markup is in the
# same response; CSS shows one or the other. Session, password, unsubscribe,
# and email-preferences stay documents.
class AppShellTest < ActionDispatch::IntegrationTest
  SHELL_PAGES = %w[/ /senate /house /polls /methodology].freeze

  test "public pages carry the bottom bar, the top-bar dispatches link, and the footer directory" do
    SHELL_PAGES.each do |path|
      get path
      assert_response :success
      assert_select "[data-testid=app-tab-bar]", { count: 1 }, path
      assert_select "[data-testid=shell-tab-dashboard][href='#{root_path}']", { text: "Dashboard", count: 1 }, path
      assert_select "[data-testid=shell-tab-senate][href='#{senate_path}']", { text: "Senate", count: 1 }, path
      assert_select "[data-testid=shell-tab-house][href='#{house_path}']", { text: "House", count: 1 }, path
      assert_select "[data-testid=shell-more][href='#site-directory']", { text: "More", count: 1 }, path
      assert_select "[data-testid=shell-dispatches][href='#{dispatches_path}']", { text: "Dispatches", count: 1 }, path
      assert_select "#site-directory a[href='#{polls_path}']", { text: "Polls", count: 1 }, path
      assert_select "#site-directory a[href='#{pollsters_path}']", { text: "Pollsters", count: 1 }, path
      assert_select "#site-directory a[href='#{methodology_path}']", { text: "Methodology", count: 1 }, path
      assert_select "#site-directory a[href='#{about_path}']", { text: "About", count: 1 }, path
      assert_select "#site-directory a[href='#{privacy_path}']", { text: "Privacy", count: 1 }, path
      assert_select "[data-testid=shell-internals-note]", { text: /Includes partisan-sponsored polls, adjusted/, count: 1 }, path
    end
  end

  test "the chamber a race belongs to stays current, and the back control names it" do
    get race_path(races(:senate_maine).slug)
    assert_select "[data-testid=shell-tab-senate][aria-current=page]"
    assert_select "[data-testid=shell-tab-house][aria-current=page]", count: 0
    assert_select "[data-testid=race-back][href='#{senate_path}']", text: "Back to Senate"

    get race_path(races(:house_ny_17).slug)
    assert_select "[data-testid=shell-tab-house][aria-current=page]"
    assert_select "[data-testid=shell-tab-senate][aria-current=page]", count: 0
    assert_select "[data-testid=race-back][href='#{house_path}']", text: "Back to House"
  end

  test "a reference page marks More current, and a dispatch marks the top-bar link" do
    get polls_path
    assert_select "[data-testid=shell-more][aria-current=page]"
    assert_select "[data-testid=shell-tab-dashboard][aria-current=page]", count: 0

    get dispatch_path(dispatches(:maine_poll_reaction))
    assert_select "[data-testid=shell-dispatches][aria-current=page]"
    assert_select "[data-testid=shell-more][aria-current=page]", count: 0
  end

  test "account and email pages stay documents" do
    subscriber = Subscriber.subscribe!(email_address: "reader@example.com")

    [ new_session_path, new_password_path, email_preferences_path, unsubscribe_path(token: subscriber.unsubscribe_token) ].each do |path|
      get path
      assert_response :success
      assert_select "[data-testid=app-tab-bar]", { count: 0 }, path
      assert_select "[data-testid=shell-dispatches]", { count: 0 }, path
      assert_select "#site-directory", { count: 0 }, path
      bar = css_select("header > div").first["class"]
      assert_includes bar, "md:grid-cols-[minmax(0,1fr)_auto]", path
    end
  end

  test "the manifest is linked and describes a live home-screen forecast" do
    get root_path
    assert_select "link[rel=manifest][href=?]", pwa_manifest_path(format: :json)

    get pwa_manifest_path(format: :json)
    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "535", manifest["short_name"]
    assert_equal "standalone", manifest["display"]
    assert_equal "/", manifest["start_url"]
    assert_equal "/", manifest["scope"]
  end
end
