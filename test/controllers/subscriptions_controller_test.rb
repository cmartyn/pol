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

  test "a first subscription is identified in PostHog and a repeat is not" do
    captured, identified = capture_posthog do
      post subscription_path, params: {
        subscriber: { email_address: "friend@example.com" }, source: "homepage"
      }
    end

    assert_equal [ "subscriber_signed_up" ], captured.map { |event| event[:event] }
    assert_equal [ "homepage" ], captured.map { |event| event.dig(:properties, :source) }
    assert_nil captured.first.dig(:properties, :email)
    assert_equal "friend@example.com", identified.first.dig(:properties, :email)
    assert_equal Subscriber.last.posthog_distinct_id, identified.first[:distinct_id]

    captured, = capture_posthog do
      post subscription_path, params: { subscriber: { email_address: "friend@example.com" } }
    end
    assert_empty captured
  end

  test "resubscribing records a separate event" do
    Subscriber.subscribe!(email_address: "friend@example.com").unsubscribe!

    captured, = capture_posthog do
      post subscription_path, params: { subscriber: { email_address: "friend@example.com" }, source: "footer" }
    end

    assert_equal [ "subscriber_resubscribed" ], captured.map { |event| event[:event] }
  end

  test "an invalid address is counted without becoming a person" do
    captured, identified = capture_posthog do
      post subscription_path, params: { subscriber: { email_address: "nope" } }
    end

    assert_equal [ "subscriber_signup_rejected" ], captured.map { |event| event[:event] }
    assert_equal false, captured.first.dig(:properties, "$process_person_profile")
    assert_empty identified
  end

  test "honeypot accepts the request without storing the address" do
    captured, = capture_posthog do
      assert_no_difference "Subscriber.count" do
        post subscription_path, params: {
          subscriber: { email_address: "bot@example.com" }, website: "spam.example"
        }
      end
    end

    assert_redirected_to root_path
    assert_empty captured
  end

  test "the turbo response names the subscriber so the browser can identify them" do
    post subscription_path,
         params: { subscriber: { email_address: "friend@example.com" }, source: "homepage" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    subscriber = Subscriber.last
    assert_response :success
    assert_select "[data-posthog-identify-distinct-id-value=?]", subscriber.posthog_distinct_id
  end

  # The reply replaces the submitted form wholesale, so a layout the reply
  # does not know about would snap the box into a different shape mid-page.
  test "an inline form comes back inline, on success and on a rejected address" do
    [ "friend@example.com", "nope" ].each do |email_address|
      post subscription_path,
           params: { subscriber: { email_address: email_address }, source: "homepage", layout: "inline" },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_select "section#subscription-form-homepage[data-layout='inline']", { count: 1 }, "#{email_address} reply lost the inline layout"
    end
  end

  # `compact` is what forms sent before `layout` existed, and a copy held at
  # the edge or left open in a tab keeps sending it after a deploy. An
  # unknown layout falls back to the plain card rather than echoing input.
  test "the layout param is read as given, from the legacy compact flag, or not at all" do
    { { layout: "compact" } => "compact",
      { compact: "true" } => "compact",
      { layout: "bogus" } => "card",
      {} => "card" }.each do |form_params, expected|
      post subscription_path,
           params: { subscriber: { email_address: "nope" }, source: "footer", **form_params },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_select "section#subscription-form-footer[data-layout='#{expected}']", { count: 1 }, "#{form_params} should render #{expected}"
    end
  end

  private
    def capture_posthog
      captured = []
      identified = []
      client = PostHog.client
      spy = Object.new
      spy.define_singleton_method(:capture) { |attrs = {}| captured << attrs }
      spy.define_singleton_method(:identify) { |attrs = {}| identified << attrs }
      PostHog.client = spy
      yield
      [ captured, identified ]
    ensure
      PostHog.client = client
    end
end
