class PollResult < ApplicationRecord
  enum :party, { dem: 0, rep: 1, ind: 2, other: 3 }

  belongs_to :poll
  belongs_to :candidate, optional: true

  validates :party, presence: true
  validates :pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
end
