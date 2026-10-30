require "test_helper"

# Where the email signup appears. The ask follows the forecast: below the
# dashboard's dispatches and below a chamber's race table, and after a
# race's chart or a dispatch. Pages without that figure keep the header
# dialog and the footer. Every copy makes the same promise, because the
# dialog cannot know which page opened it.
class SubscriptionPlacementTest < ActionDispatch::IntegrationTest
  FIGURE_BANDS = { "/" => "homepage", "/senate" => "senate", "/house" => "house" }.freeze
  QUIET_PAGES = %w[/polls /pollsters /methodology /about /dispatches].freeze

  test "the ask follows the figure, with one promise" do
    FIGURE_BANDS.each do |path, source|
      get path
      assert_response :success
      assert_select "main #subscription-form-#{source}[data-layout='band']", { count: 1 }, path
      assert_select "main #subscription-form-#{source} h2", text: "The forecast, in your inbox"
      assert_select "main #subscription-form-#{source} [data-testid='subscription-promise']", text: "A dispatch when the numbers move."
    end

    get race_path(races(:senate_maine).slug)
    assert_select "main #subscription-form-race[data-layout='card']", count: 1
    body = response.body
    # After the forecast and the line it moved on, before the poll table.
    assert_operator body.index("forecast-detail"), :<, body.index("Win probability over time")
    assert_operator body.index("Win probability over time"), :<, body.index("subscription-form-race")
    assert_operator body.index("subscription-form-race"), :<, body.index("data-testid=\"poll-table\"")

    get dispatch_path(dispatches(:maine_poll_reaction))
    assert_select "main #subscription-form-dispatch[data-layout='card']", count: 1
    body = response.body
    assert_operator body.index("dispatch-sources"), :<, body.index("subscription-form-dispatch")

    get senate_path
    body = response.body
    assert_operator body.index("table-filter"), :<, body.index("subscription-form-senate")

    get house_path
    body = response.body
    assert_operator body.index("table-filter"), :<, body.index("subscription-form-house")
  end

  test "each copy of the email field has its own id" do
    get root_path

    email_ids = css_select("input[type=email]").map { |node| node["id"] }
    assert_equal email_ids.uniq, email_ids
    assert_equal(
      %w[subscriber_email_address_dialog subscriber_email_address_footer subscriber_email_address_homepage],
      email_ids.sort
    )
    email_ids.each do |id|
      assert_select "label[for='#{id}']", count: 1
      assert_select "input##{id}[name='subscriber[email_address]']", count: 1
    end
    website_ids = css_select("input[name=website]").map { |node| node["id"] }
    assert_equal website_ids.uniq, website_ids

    get race_path(races(:senate_maine).slug)
    race_ids = css_select("input[type=email]").map { |node| node["id"] }
    assert_equal race_ids.uniq, race_ids
    assert_includes race_ids, "subscriber_email_address_race"
  end

  test "the dialog and the footer use the same promise" do
    get race_path(races(:senate_maine).slug)
    assert_select "#subscription-form-dialog h2", text: "The forecast, in your inbox"
    assert_select "#subscription-form-dialog [data-testid='subscription-promise']", text: "A dispatch when the numbers move."
    assert_select "footer #subscription-form-footer h2", text: "The forecast, in your inbox"
  end

  test "pages without a forecast figure keep the ask out of the article" do
    QUIET_PAGES.each do |path|
      get path
      assert_response :success
      assert_select "main [data-testid='subscription-form']", { count: 0 }, "#{path} should not put a signup in the article"
      assert_select "footer #subscription-form-footer", { count: 1 }, "#{path} should keep the footer signup"
    end
  end

  test "pages about managing or the terms of a subscription carry no in-page signup" do
    subscriber = Subscriber.subscribe!(email_address: "reader@example.com")

    [ privacy_path, email_preferences_path, unsubscribe_path(token: subscriber.unsubscribe_token), race_path("no-such-race") ].each do |path|
      get path
      assert_select "main [data-testid='subscription-form']", { count: 0 }, "#{path} should not carry an in-page signup"
    end
  end

  # The header link opens the form in a dialog. Its href still points at the
  # footer's copy, which is where it goes with JavaScript off.
  test "every page's header Subscribe link opens the dialog, and falls back to the footer form" do
    [ root_path, senate_path, privacy_path ].each do |path|
      get path
      assert_select "header a[href='#subscription-form-footer'][data-action~='subscribe-dialog#open']", { text: "Subscribe", count: 1 }, path
      assert_select "dialog[data-subscribe-dialog-target='dialog'] #subscription-form-dialog[data-layout='dialog'] input[type=email]", { count: 1 }, path
    end
  end
end
