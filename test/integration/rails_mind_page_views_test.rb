require "test_helper"

# What rails_mind 0.4.1 page views do outside the edge-cached pages, whose
# no-cookie promise EdgeCachingTest pins: the visitor cookie does appear on a
# page Cloudflare never holds, and the secrets that unsubscribe and
# password-reset links carry in their path never reach RailsMind.
class RailsMindPageViewsTest < ActionDispatch::IntegrationTest
  VISITOR_COOKIE = /\A_rails_mind_visitor=(\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}); path=\/; expires=[^;]+; httponly; samesite=lax\z/i

  test "an uncached page counts a page view and sets the visitor cookie" do
    with_rails_mind_collecting do |events|
      get email_preferences_path, headers: BROWSER_HEADERS

      assert_response :success
      cookie = Array(response.headers["Set-Cookie"]).flat_map { |header| header.split("\n") }
        .find { |header| header.start_with?("_rails_mind_visitor=") }
      assert_match VISITOR_COOKIE, cookie
      view = page_views(events).sole
      assert_equal "SubscriptionPreferencesController#show", view["name"]
      assert_equal "cookie", view.dig("properties", "visitor_id_kind")
      assert_equal cookie[VISITOR_COOKIE, 1], view["visitor_id"]
    end
  end

  # The browser unsubscribe button posts from the unsubscribe page and lands on
  # email preferences, so that page view's referrer is the unsubscribe link: a
  # browser keeps the form's page as the referrer across the redirect. A
  # referrer inside the app is sent as its origin only.
  test "an unsubscribe link's secret reaches RailsMind neither as a path nor as a referrer" do
    subscriber = Subscriber.subscribe!(email_address: "reader@example.com")
    token = subscriber.unsubscribe_token
    from_unsubscribe = BROWSER_HEADERS.merge("HTTP_REFERER" => unsubscribe_url(token: token))

    with_rails_mind_collecting do |events|
      get unsubscribe_path(token: token), headers: BROWSER_HEADERS
      assert_response :success
      post unsubscribe_path(token: token), params: { browser_confirmation: "1" }, headers: from_unsubscribe
      follow_redirect!(headers: from_unsubscribe)
      assert_response :success

      unsubscribe, preferences = page_views(events)
      assert_equal "/unsubscribe/:token", unsubscribe.dig("properties", "route")
      assert_equal "/unsubscribe/[FILTERED]", unsubscribe.dig("properties", "path")
      assert_equal "SubscriptionPreferencesController#show", preferences["name"]
      assert_equal "http://www.example.com", preferences.dig("properties", "referrer")
      assert_secret_omitted events, token
    end
  end

  test "a password reset link's secret reaches RailsMind neither as a path nor as a referrer" do
    token = users(:one).password_reset_token
    from_reset = BROWSER_HEADERS.merge("HTTP_REFERER" => edit_password_url(token))

    with_rails_mind_collecting do |events|
      get new_password_path, headers: BROWSER_HEADERS
      get edit_password_path(token), headers: BROWSER_HEADERS
      assert_response :success
      patch password_path(token), params: { password: "a new passphrase", password_confirmation: "a new passphrase" },
        headers: from_reset
      follow_redirect!(headers: from_reset)
      assert_response :success
      # The form's own address, should anything ever be reached from it.
      get new_session_path, headers: BROWSER_HEADERS.merge("HTTP_REFERER" => password_url(token))

      requested, reset, signed_out, from_form = page_views(events)
      assert_equal "/passwords/new", requested.dig("properties", "path")
      assert_equal "/passwords/[FILTERED]/edit", reset.dig("properties", "path")
      assert_equal "SessionsController#new", signed_out["name"]
      assert_equal "http://www.example.com", signed_out.dig("properties", "referrer")
      assert_equal "http://www.example.com", from_form.dig("properties", "referrer")
      assert_secret_omitted events, token
    end
  end

  # The tests above pass on rails_mind 0.4.1's own masking alone, so this
  # checks the initializer's second guard by itself.
  test "the initializer masks unsubscribe and password-reset secrets too" do
    event = { "kind" => "pageview", "properties" => {
      "path" => "/unsubscribe/abc123?ref=mail", "referrer" => "https://pol.example/passwords/def456/edit"
    } }
    properties = RailsMind.configuration.before_send.call(event)["properties"]

    assert_equal "/unsubscribe/[FILTERED]?ref=mail", properties["path"]
    assert_equal "https://pol.example/passwords/[FILTERED]/edit", properties["referrer"]
  end

  private
    def assert_secret_omitted(events, token)
      json = events.to_json
      [ token, ERB::Util.url_encode(token), token.split("--").last ].each do |form|
        assert_not_includes json, form
      end
    end
end
