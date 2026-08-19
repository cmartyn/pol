class SendDispatchEmailJob < ApplicationJob
  queue_as :mailers

  retry_on Resend::Client::TemporaryError, wait: :polynomially_longer, attempts: 8 do |job, error|
    delivery = DispatchDelivery.find_by(id: job.arguments.first)
    delivery&.update!(status: :failed, failed_at: Time.current, last_error: error.message)
  end

  def perform(delivery_id)
    return unless DispatchEmail.enabled?

    delivery = DispatchDelivery.includes(:dispatch, :subscriber).find(delivery_id)
    return if delivery.terminal?

    unless delivery.subscriber.subscribed? && delivery.dispatch.published?
      delivery.update!(status: :skipped, last_error: "recipient unsubscribed or dispatch retracted before send")
      return
    end

    prepare_payload!(delivery)

    resend_id = Resend::Client.new.send_email!(
      from: mail_from,
      to: delivery.to_address,
      subject: delivery.subject,
      html: delivery.html_body,
      text: delivery.text_body,
      reply_to: mail_reply_to,
      headers: unsubscribe_headers(delivery.subscriber),
      tags: [
        { name: "category", value: "dispatch" },
        { name: "dispatch_id", value: delivery.dispatch_id.to_s },
        { name: "delivery_id", value: delivery.id.to_s }
      ],
      idempotency_key: delivery.idempotency_key
    )

    delivery.update!(status: :sent, resend_email_id: resend_id, sent_at: Time.current, last_error: nil)
  rescue Resend::Client::PermanentError, Resend::Client::ConfigurationError => error
    delivery&.update!(status: :failed, failed_at: Time.current, last_error: error.message)
  end

  private
    def prepare_payload!(delivery)
      delivery.with_lock do
        if delivery.subject.blank?
          message = DispatchMailer.with(delivery: delivery).dispatch_update
          delivery.subject = message.subject
          delivery.html_body = message.html_part.body.decoded
          delivery.text_body = message.text_part.body.decoded
        end

        delivery.status = :sending
        delivery.attempts += 1
        delivery.save!
      end
    end

    def unsubscribe_headers(subscriber)
      url = Rails.application.routes.url_helpers.unsubscribe_url(
        token: subscriber.unsubscribe_token,
        host: canonical_host,
        protocol: "https"
      )
      {
        "List-Unsubscribe" => "<#{url}>",
        "List-Unsubscribe-Post" => "List-Unsubscribe=One-Click"
      }
    end

    def canonical_host
      ENV.fetch("CANONICAL_HOST", "535.wtf")
    end

    def mail_from
      ENV.fetch("MAIL_FROM", "535.wtf <robot@535.wtf>")
    end

    def mail_reply_to
      ENV.fetch("MAIL_REPLY_TO", "cmartyn@gmail.com")
    end
end
