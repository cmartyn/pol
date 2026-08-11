class Dispatch < ApplicationRecord
  enum :kind, { poll_reaction: 0, movement_note: 1, daily_brief: 2 }
  enum :status, { published: 0, retracted: 1 }

  belongs_to :race, optional: true
  belongs_to :model_run, optional: true

  validates :headline, presence: true
  validates :body_markdown, presence: true
  validate :headline_within_max_chars

  scope :recent_first, -> { order(published_at: :desc, id: :desc) }

  private
    # Reads the cap from Pol::Params on every validation run rather than
    # caching it in a constant, so editing config/model_params.yml takes
    # effect without a restart-triggering code change.
    def headline_within_max_chars
      return if headline.blank?

      max_chars = Pol::Params.fetch!(:newsroom, :headline_max_chars)
      errors.add(:headline, "is too long (maximum is #{max_chars} characters)") if headline.length > max_chars
    end
end
