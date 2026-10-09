require "test_helper"

# Where the email signup appears, page by page. The homepage proved the
# headline row is the one place that clears the fold on every phone and
# laptop; every page a reader lands on to read the forecast gets the same row,
# with its own source so conversions can be told apart. Pages that are about
# managing an existing subscription, or about the legal terms of one, don't.
class SubscriptionPlacementTest < ActionDispatch::IntegrationTest
  HEADLINE_SOURCES = {
    "/" => "homepage",
    "/senate" => "senate",
    "/house" => "house",
    "/polls" => "polls",
    "/pollsters" => "pollsters",
    "/methodology" => "methodology",
    "/about" => "about",
    "/dispatches" => "dispatches-index"
  }.freeze

  test "every reading page carries one inline signup, ahead of its first section" do
    paths = HEADLINE_SOURCES.merge(race_path(races(:senate_maine).slug) => "race")

    paths.each do |path, source|
      get path
      assert_response :success

      assert_select "main [data-testid='subscription-form']", { count: 1 }, "#{path} should carry exactly one in-page signup"
      assert_select "main #subscription-form-#{source}[data-layout='inline'] input[type=email]", { count: 1 }, "#{path} should label its signup #{source}"

      # Above the fold means above the page's own content: before its
      # first section (the form is a section itself, so not that one), or
      # the race page's forecast detail.
      body = response.body
      first_content = [ body.index(/<section(?![^>]*id="subscription-form-)/), body.index("data-testid=\"forecast-detail\"") ].compact.min
      form = body.index("id=\"subscription-form-#{source}\"")
      assert_operator form, :<, first_content, "#{path} puts its signup below the page's content" if first_content
    end
  end

  # The race page's reader came for one race, and the newsletter covers all
  # of them. The heading has to say so rather than leave "every dispatch" to
  # be read as every dispatch about this race.
  test "the race page's signup says it covers every race" do
    get race_path(races(:senate_maine).slug)
    assert_select "#subscription-form-race h2", text: /every race/
    # The header dialog opens over race pages too, and its reply can't know
    # which page it's on — so it says every race everywhere.
    assert_select "#subscription-form-dialog h2", text: /every race/

    get senate_path
    assert_select "#subscription-form-senate h2", text: "Get every dispatch by email"
  end

  test "a dispatch keeps its signup at the end of the article, not above the headline" do
    dispatch = dispatches(:maine_poll_reaction)
    get dispatch_path(dispatch)

    assert_select "main [data-testid='subscription-form']", count: 1
    assert_select "main #subscription-form-dispatch-show[data-layout='card']", count: 1
    assert_operator response.body.index("data-testid=\"dispatch-headline\""), :<, response.body.index("id=\"subscription-form-dispatch-show\"")
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
