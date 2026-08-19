module Resend
  class EventHandler
    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event
      @type = event.fetch("type")
      @data = event.fetch("data", {})
    end

    def call
      delivery = DispatchDelivery.find_by(resend_email_id: email_id)
      return unless delivery

      occurred_at = parse_time(@event["created_at"]) || Time.current

      case @type
      when "email.sent"
        delivery.update!(status: :sent, sent_at: delivery.sent_at || occurred_at) unless delivery.delivered?
      when "email.delivered"
        delivery.update!(status: :delivered, delivered_at: occurred_at)
      when "email.delivery_delayed"
        delivery.update!(status: :delayed) unless delivery.delivered?
      when "email.failed"
        delivery.update!(status: :failed, failed_at: occurred_at, last_error: event_detail)
      when "email.bounced"
        suppress!(delivery, :bounced, occurred_at)
      when "email.complained"
        suppress!(delivery, :complained, occurred_at)
      when "email.suppressed"
        suppress!(delivery, :suppressed, occurred_at)
      end
    end

    private
      def email_id
        @data["email_id"] || @data["id"]
      end

      def suppress!(delivery, status, occurred_at)
        delivery.update!(status: status, failed_at: occurred_at, last_error: event_detail)
        delivery.subscriber.suppress!(reason: status, occurred_at: occurred_at)
      end

      def event_detail
        detail = @data[@type.delete_prefix("email.")] || @data["error"]
        detail.is_a?(Hash) ? (detail["message"] || detail["type"]) : detail.to_s.presence
      end

      def parse_time(value)
        Time.zone.parse(value) if value.present?
      rescue ArgumentError
        nil
      end
  end
end
