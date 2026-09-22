require "test_helper"

class Admin::SubscribersControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "redirects unauthenticated visitors to sign-in" do
    sign_out
    get admin_subscribers_path
    assert_redirected_to new_session_path
  end

  test "lists current subscribers and hides people who left" do
    current = Subscriber.subscribe!(email_address: "reader@example.com", source: "homepage")
    former = Subscriber.subscribe!(email_address: "former@example.com").tap(&:unsubscribe!)

    get admin_subscribers_path

    assert_response :success
    assert_select "[data-testid='admin-subscribers-subscribed-count']", text: "1"
    assert_select "[data-testid='admin-subscribers-unsubscribed-count']", text: "1"
    assert_select "[data-testid='admin-subscriber-row']", text: /reader@example.com/
    assert_select "[data-testid='admin-subscriber-row']", text: /former@example.com/, count: 0
    assert_select "a[href='#{admin_subscriber_path(current)}']"
    assert_select "a[href='#{admin_subscriber_path(former)}']", count: 0
  end

  test "filters by status and email" do
    Subscriber.subscribe!(email_address: "reader@example.com")
    Subscriber.subscribe!(email_address: "former@example.com").unsubscribe!
    Subscriber.subscribe!(email_address: "bounce@example.com").suppress!(reason: :bounced)

    get admin_subscribers_path, params: { status: "all" }
    assert_select "[data-testid='admin-subscriber-row']", count: 3

    get admin_subscribers_path, params: { status: "suppressed" }
    assert_select "[data-testid='admin-subscriber-row']", count: 1
    assert_select "[data-testid='admin-subscriber-row']", text: /bounce@example.com/

    get admin_subscribers_path, params: { status: "all", q: "READ" }
    assert_select "[data-testid='admin-subscriber-row']", count: 1
    assert_select "[data-testid='admin-subscriber-row']", text: /reader@example.com/
  end

  test "shows an empty state when nobody matches" do
    get admin_subscribers_path
    assert_select "[data-testid='admin-subscribers-empty']"
  end

  test "show includes source, suppression, and deliveries" do
    subscriber = Subscriber.subscribe!(email_address: "reader@example.com", source: "dispatch-show")
    subscriber.suppress!(reason: :complained)
    DispatchDelivery.create!(
      dispatch: dispatches(:maine_poll_reaction),
      subscriber: subscriber,
      to_address: subscriber.email_address,
      status: :bounced
    )

    get admin_subscriber_path(subscriber)

    assert_response :success
    assert_select "[data-testid='admin-subscriber-email']", text: "reader@example.com"
    assert_select "[data-testid='admin-subscriber-status']", text: "suppressed"
    assert_select "[data-testid='admin-subscriber-source']", text: "dispatch-show"
    assert_select "[data-testid='admin-subscriber-suppression']", text: "complained"
    assert_select "[data-testid='admin-subscriber-delivery']", text: /#{Regexp.escape(dispatches(:maine_poll_reaction).headline)}/
  end

  test "show explains when nothing has been sent" do
    subscriber = Subscriber.subscribe!(email_address: "reader@example.com")

    get admin_subscriber_path(subscriber)

    assert_select "[data-testid='admin-subscriber-deliveries-empty']"
  end
end
