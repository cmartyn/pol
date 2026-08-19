require "test_helper"

class SubscriptionPreferencesControllerTest < ActionDispatch::IntegrationTest
  test "shows the secure preferences form" do
    get email_preferences_path

    assert_response :success
    assert_select "form[action=?]", email_preferences_path
  end

  test "emails a management link to an active subscriber" do
    subscriber = Subscriber.subscribe!(email_address: "friend@example.com")

    assert_enqueued_email_with SubscriberMailer, :manage, params: { subscriber: subscriber } do
      post email_preferences_path, params: { subscriber: { email_address: "FRIEND@example.com" } }
    end

    assert_redirected_to email_preferences_path
  end

  test "unknown and inactive addresses get the same response without an email" do
    Subscriber.subscribe!(email_address: "former@example.com").unsubscribe!

    assert_no_enqueued_emails do
      post email_preferences_path, params: { subscriber: { email_address: "missing@example.com" } }
      post email_preferences_path, params: { subscriber: { email_address: "former@example.com" } }
    end

    assert_redirected_to email_preferences_path
  end
end
