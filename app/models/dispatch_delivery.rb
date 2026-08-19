class DispatchDelivery < ApplicationRecord
  enum :status, {
    pending: 0,
    sending: 1,
    sent: 2,
    delivered: 3,
    delayed: 4,
    failed: 5,
    bounced: 6,
    complained: 7,
    suppressed: 8,
    skipped: 9
  }

  belongs_to :dispatch
  belongs_to :subscriber

  scope :terminal, -> { where(status: %i[sent delivered failed bounced complained suppressed skipped]) }

  def terminal?
    sent? || delivered? || failed? || bounced? || complained? || suppressed? || skipped?
  end

  def idempotency_key
    "dispatch-email/#{id}"
  end
end
