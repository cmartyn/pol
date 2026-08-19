require "test_helper"

class UnsubscribesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @subscriber = Subscriber.subscribe!(email_address: "friend@example.com")
    @token = @subscriber.unsubscribe_token
  end

  test "GET confirms without unsubscribing" do
    get unsubscribe_path(token: @token)

    assert_response :success
    assert_predicate @subscriber.reload, :subscribed?
    assert_select "form[action=?]", unsubscribe_path(token: @token)
  end

  test "browser confirmation unsubscribes and redirects" do
    post unsubscribe_path(token: @token), params: { browser_confirmation: "1" }

    assert_redirected_to email_preferences_path
    assert_predicate @subscriber.reload, :unsubscribed?
  end

  test "one-click provider POST unsubscribes and returns an empty success" do
    post unsubscribe_path(token: @token), params: { "List-Unsubscribe" => "One-Click" }

    assert_response :success
    assert_predicate @subscriber.reload, :unsubscribed?
  end

  test "invalid tokens do not disclose an address" do
    get unsubscribe_path(token: "bad-token")
    assert_response :not_found

    post unsubscribe_path(token: "bad-token"), params: { "List-Unsubscribe" => "One-Click" }
    assert_response :success
  end
end
