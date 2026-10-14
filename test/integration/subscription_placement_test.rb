require "test_helper"

# Where the email signup appears, page by page. The forecast is the headline,
# so a reading page does not carry its own form. Subscribe lives in the header
# dialog and the footer, which every public page renders. Pages that are about
# managing an existing subscription, or about the legal terms of one, still
# have the footer and the dialog — they just don't add a third form in the article.
class SubscriptionPlacementTest < ActionDispatch::IntegrationTest
  READING_PAGES = %w[/ /senate /house /polls /pollsters /methodology /about /dispatches].freeze

  test "reading pages keep the signup out of the article" do
    paths = READING_PAGES + [ race_path(races(:senate_maine).slug), dispatch_path(dispatches(:maine_poll_reaction)) ]

    paths.each do |path|
      get path
      assert_response :success

      assert_select "main [data-testid='subscription-form']", { count: 0 }, "#{path} should not put a signup in the article"
      assert_select "footer #subscription-form-footer", { count: 1 }, "#{path} should keep the footer signup"
    end
  end

  # The header dialog opens over race pages too, and its reply can't know
  # which page it's on — so it says every race everywhere. A reader who came
  # for one race could otherwise hear "every dispatch" as every dispatch
  # about that race.
  test "the header dialog says the newsletter covers every race" do
    get race_path(races(:senate_maine).slug)
    assert_select "#subscription-form-dialog h2", text: /every race/
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
