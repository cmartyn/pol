class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  # Called by posthog-rails for automatic user association in error reports.
  # Uses the primary key, not the email — an email can change, which would
  # split one person's history in two, and it is PII on every event's identity.
  def posthog_distinct_id
    id.to_s
  end

  # Person properties sent to PostHog on identify(). These appear on the
  # person profile and are never embedded in event properties directly.
  def posthog_properties
    { email: email_address }
  end
end
