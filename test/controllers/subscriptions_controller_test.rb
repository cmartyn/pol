require "test_helper"

class SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  test "subscribes immediately without sending a confirmation email" do
    assert_difference "Subscriber.count", 1 do
      assert_no_enqueued_emails do
        post subscription_path, params: {
          subscriber: { email_address: "Friend@Example.com" },
          source: "homepage"
        }
      end
    end

    assert_redirected_to root_path
    assert_equal "friend@example.com", Subscriber.last.email_address
    assert_predicate Subscriber.last, :subscribed?
  end

  test "duplicate subscription does not disclose or duplicate the record" do
    Subscriber.subscribe!(email_address: "friend@example.com")

    assert_no_difference "Subscriber.count" do
      post subscription_path, params: { subscriber: { email_address: "FRIEND@example.com" } }
    end

    assert_redirected_to root_path
  end

  test "invalid email returns a friendly error" do
    assert_no_difference "Subscriber.count" do
      post subscription_path, params: { subscriber: { email_address: "nope" } }
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_select "[role='alert']", text: /valid email address/
  end

  test "honeypot accepts the request without storing the address" do
    assert_no_difference "Subscriber.count" do
      post subscription_path, params: {
        subscriber: { email_address: "bot@example.com" }, website: "spam.example"
      }
    end

    assert_redirected_to root_path
  end
end
