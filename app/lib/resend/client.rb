require "net/http"

module Resend
  class Client
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        @status = status
        super(message)
      end
    end

    class ConfigurationError < Error; end
    class TemporaryError < Error; end
    class PermanentError < Error; end

    ENDPOINT = URI("https://api.resend.com/emails")

    def initialize(api_key: ENV["RESEND_API_KEY"].presence || Rails.application.credentials.resend_api_key)
      @api_key = api_key.to_s
    end

    def send_email!(from:, to:, subject:, html:, text:, reply_to:, headers:, tags:, idempotency_key:)
      raise ConfigurationError, "Resend API key is not configured" if @api_key.blank?

      request = Net::HTTP::Post.new(ENDPOINT)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = idempotency_key
      request.body = {
        from: from,
        to: [ to ],
        subject: subject,
        html: html,
        text: text,
        reply_to: reply_to,
        headers: headers,
        tags: tags
      }.to_json

      response = Net::HTTP.start(
        ENDPOINT.host,
        ENDPOINT.port,
        use_ssl: true,
        open_timeout: 5,
        read_timeout: 15,
        write_timeout: 15
      ) { |http| http.request(request) }

      body = JSON.parse(response.body.presence || "{}")
      return body.fetch("id") if response.is_a?(Net::HTTPSuccess)

      error_class = response.code.to_i == 429 || response.code.to_i >= 500 ? TemporaryError : PermanentError
      detail = body["message"].presence || body["name"].presence || "Resend request failed"
      raise error_class.new("#{detail.to_s.first(300)} (HTTP #{response.code})", status: response.code.to_i)
    rescue JSON::ParserError => error
      raise TemporaryError, "Resend returned an unreadable response: #{error.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, EOFError, Errno::ECONNRESET => error
      raise TemporaryError, "Resend request failed: #{error.class}"
    end
  end
end
