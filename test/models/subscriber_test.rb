require "test_helper"

class SubscriberTest < ActiveSupport::TestCase
  test "subscribe normalizes and records an address immediately" do
    subscriber = Subscriber.subscribe!(email_address: " FRIEND@Example.COM ", source: "homepage")

    assert_predicate subscriber, :subscribed?
    assert_equal "friend@example.com", subscriber.email_address
    assert_equal "homepage", subscriber.source
    assert subscriber.subscribed_at.present?
  end

  test "subscribing the same address is idempotent" do
    original = Subscriber.subscribe!(email_address: "friend@example.com")

    assert_no_difference "Subscriber.count" do
      again = Subscriber.subscribe!(email_address: "FRIEND@example.com")
      assert_equal original, again
    end
  end

  test "resubscribing reactivates the address and invalidates old unsubscribe links" do
    subscriber = Subscriber.subscribe!(email_address: "friend@example.com")
    old_token = subscriber.unsubscribe_token
    subscriber.unsubscribe!

    reactivated = Subscriber.subscribe!(email_address: subscriber.email_address)

    assert_predicate reactivated, :subscribed?
    assert_nil reactivated.unsubscribed_at
    assert_nil Subscriber.from_unsubscribe_token(old_token)
    assert_equal reactivated, Subscriber.from_unsubscribe_token(reactivated.unsubscribe_token)
  end

  test "suppression records the provider reason" do
    subscriber = Subscriber.subscribe!(email_address: "bounce@example.com")
    occurred_at = Time.current.change(usec: 0)

    subscriber.suppress!(reason: :bounced, occurred_at: occurred_at)

    assert_predicate subscriber, :suppressed?
    assert_equal "bounced", subscriber.suppression_reason
    assert_equal occurred_at, subscriber.last_resend_event_at
  end

  test "rejects an invalid address" do
    assert_raises ActiveRecord::RecordInvalid do
      Subscriber.subscribe!(email_address: "not an email")
    end
  end
end
