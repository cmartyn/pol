require "test_helper"

class SendDispatchEmailJobTest < ActiveJob::TestCase
  setup do
    @old_enabled = ENV["DISPATCH_EMAILS_ENABLED"]
    @old_key = ENV["RESEND_API_KEY"]
    ENV["DISPATCH_EMAILS_ENABLED"] = "true"
    ENV["RESEND_API_KEY"] = "re_test"

    @subscriber = Subscriber.subscribe!(email_address: "friend@example.com")
    @dispatch = dispatches(:maine_poll_reaction)
    @delivery = DispatchDelivery.create!(
      dispatch: @dispatch, subscriber: @subscriber, to_address: @subscriber.email_address
    )
  end

  teardown do
    ENV["DISPATCH_EMAILS_ENABLED"] = @old_enabled
    ENV["RESEND_API_KEY"] = @old_key
  end

  test "sends an excerpt with canonical and one-click unsubscribe links" do
    request = stub_request(:post, "https://api.resend.com/emails")
      .with(headers: { "Idempotency-Key" => @delivery.idempotency_key })
      .to_return(status: 200, body: { id: "email_sent_123" }.to_json, headers: { "Content-Type" => "application/json" })

    SendDispatchEmailJob.perform_now(@delivery.id)

    assert_requested request, times: 1
    assert_predicate @delivery.reload, :sent?
    assert_equal "email_sent_123", @delivery.resend_email_id
    assert_includes @delivery.html_body, "Read the full dispatch"
    assert_includes @delivery.html_body, "https://535.wtf/dispatches/"
    assert_includes @delivery.text_body, "Unsubscribe: https://535.wtf/unsubscribe/"

    sent_body = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.first.body)
    assert_equal [ "friend@example.com" ], sent_body.fetch("to")
    assert_equal "List-Unsubscribe=One-Click", sent_body.dig("headers", "List-Unsubscribe-Post")
  end

  test "skips a recipient who unsubscribed before send" do
    @subscriber.unsubscribe!

    SendDispatchEmailJob.perform_now(@delivery.id)

    assert_not_requested :post, "https://api.resend.com/emails"
    assert_predicate @delivery.reload, :skipped?
  end
end
