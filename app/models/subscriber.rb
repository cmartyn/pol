class Subscriber < ApplicationRecord
  EMAIL_PATTERN = URI::MailTo::EMAIL_REGEXP

  enum :status, { subscribed: 0, unsubscribed: 1, suppressed: 2 }

  has_many :dispatch_deliveries, dependent: :restrict_with_exception

  normalizes :email_address, with: ->(value) { value.to_s.strip.downcase }

  validates :email_address, presence: true, format: { with: EMAIL_PATTERN }
  validates :subscribed_at, presence: true

  def self.subscribe!(email_address:, source: nil)
    normalized = normalize_value_for(:email_address, email_address)

    transaction(requires_new: true) do
      subscriber = lock.find_or_initialize_by(email_address: normalized)
      subscriber.source = source.to_s.first(50).presence

      if subscriber.new_record?
        subscriber.subscribed_at = Time.current
      elsif !subscriber.subscribed?
        subscriber.status = :subscribed
        subscriber.subscribed_at = Time.current
        subscriber.unsubscribed_at = nil
        subscriber.suppression_reason = nil
        subscriber.token_version += 1
      end

      subscriber.save!
      subscriber
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def unsubscribe!
    return self if unsubscribed?

    update!(status: :unsubscribed, unsubscribed_at: Time.current, suppression_reason: nil)
    self
  end

  def suppress!(reason:, occurred_at: Time.current)
    update!(
      status: :suppressed,
      unsubscribed_at: occurred_at,
      suppression_reason: reason.to_s.first(100),
      last_resend_event_at: occurred_at
    )
    self
  end

  def unsubscribe_token
    self.class.unsubscribe_verifier.generate(
      { "id" => id, "version" => token_version },
      purpose: :unsubscribe
    )
  end

  def self.from_unsubscribe_token(token)
    payload = unsubscribe_verifier.verified(token.to_s, purpose: :unsubscribe)
    return unless payload.is_a?(Hash)

    find_by(id: payload["id"], token_version: payload["version"])
  end

  def self.unsubscribe_verifier
    Rails.application.message_verifier(:subscriber_unsubscribe)
  end
end
