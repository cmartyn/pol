class ResendWebhooksController < PublicController
  skip_forgery_protection

  def create
    payload = request.raw_post
    event_id = request.headers["svix-id"]

    unless verifier.valid?(
      payload: payload,
      event_id: event_id,
      timestamp: request.headers["svix-timestamp"],
      signature: request.headers["svix-signature"]
    )
      return head :bad_request
    end

    event = JSON.parse(payload)

    ResendWebhookEvent.transaction do
      ResendWebhookEvent.create!(event_id: event_id, event_type: event.fetch("type"), processed_at: Time.current)
      Resend::EventHandler.call(event)
    end

    head :ok
  rescue ActiveRecord::RecordNotUnique
    head :ok
  rescue JSON::ParserError, KeyError
    head :unprocessable_content
  end

  private
    def verifier
      Resend::WebhookVerifier.new
    end
end
