class ResendWebhookEvent < ApplicationRecord
  validates :event_id, :event_type, :processed_at, presence: true
end
