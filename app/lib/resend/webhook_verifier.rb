require "base64"
require "openssl"

module Resend
  class WebhookVerifier
    TOLERANCE = 5.minutes

    def initialize(
      secret: ENV["RESEND_WEBHOOK_SECRET"].presence || Rails.application.credentials.resend_webhook_secret,
      now: -> { Time.current }
    )
      @secret = secret.to_s
      @now = now
    end

    def valid?(payload:, event_id:, timestamp:, signature:)
      return false if @secret.blank? || event_id.blank? || timestamp.blank? || signature.blank?

      signed_at = Time.zone.at(Integer(timestamp, 10))
      return false if (@now.call - signed_at).abs > TOLERANCE

      key = Base64.decode64(@secret.delete_prefix("whsec_"))
      expected = Base64.strict_encode64(
        OpenSSL::HMAC.digest("SHA256", key, "#{event_id}.#{timestamp}.#{payload}")
      )

      signature.split.any? do |candidate|
        version, value = candidate.split(",", 2)
        version == "v1" && value.present? && secure_compare(expected, value)
      end
    rescue ArgumentError
      false
    end

    private
      def secure_compare(expected, actual)
        return false unless expected.bytesize == actual.bytesize

        ActiveSupport::SecurityUtils.secure_compare(expected, actual)
      end
  end
end
