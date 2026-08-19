require "test_helper"
require "base64"
require "openssl"

class ResendWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @old_secret = ENV["RESEND_WEBHOOK_SECRET"]
    signing_key = Base64.strict_encode64("test signing key")
    ENV["RESEND_WEBHOOK_SECRET"] = "whsec_#{signing_key}"

    subscriber = Subscriber.subscribe!(email_address: "friend@example.com")
    @delivery = DispatchDelivery.create!(
      dispatch: dispatches(:maine_poll_reaction), subscriber: subscriber,
      to_address: subscriber.email_address, status: :sent, resend_email_id: "email_123"
    )
  end

  teardown do
    ENV["RESEND_WEBHOOK_SECRET"] = @old_secret
  end

  test "verified delivery events update the delivery once" do
    payload = event_payload("email.delivered")

    assert_difference "ResendWebhookEvent.count", 1 do
      post_signed(payload, event_id: "event_1")
    end
    assert_response :success
    assert_predicate @delivery.reload, :delivered?

    assert_no_difference "ResendWebhookEvent.count" do
      post_signed(payload, event_id: "event_1")
    end
    assert_response :success
  end

  test "bounce suppresses the subscriber" do
    post_signed(event_payload("email.bounced"), event_id: "event_2")

    assert_response :success
    assert_predicate @delivery.reload, :bounced?
    assert_predicate @delivery.subscriber.reload, :suppressed?
  end

  test "rejects an invalid signature" do
    post resend_webhook_path,
         params: event_payload("email.delivered"),
         headers: { "svix-id" => "event_bad", "svix-timestamp" => Time.now.to_i.to_s, "svix-signature" => "v1,bad" }

    assert_response :bad_request
    assert_predicate @delivery.reload, :sent?
  end

  private
    def event_payload(type)
      { type: type, created_at: Time.current.iso8601, data: { email_id: "email_123" } }.to_json
    end

    def post_signed(payload, event_id:)
      timestamp = Time.now.to_i.to_s
      key = Base64.decode64(ENV.fetch("RESEND_WEBHOOK_SECRET").delete_prefix("whsec_"))
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{event_id}.#{timestamp}.#{payload}"))

      post resend_webhook_path,
           params: payload,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "svix-id" => event_id,
             "svix-timestamp" => timestamp,
             "svix-signature" => "v1,#{signature}"
           }
    end
end
