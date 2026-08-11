class Dispatch < ApplicationRecord
  enum :kind, { poll_reaction: 0, movement_note: 1, daily_brief: 2 }
  enum :status, { published: 0, retracted: 1 }

  belongs_to :race, optional: true
  belongs_to :model_run, optional: true

  validates :headline, presence: true
  validates :body_markdown, presence: true
  validate :headline_within_max_chars

  scope :recent_first, -> { order(published_at: :desc, id: :desc) }

  # Dispatches citing any of the given poll ids — the newsroom's duplicate
  # guard, so the same poll is never reacted to twice.
  #
  # One containment test per id, OR'd: `@>` is the jsonb operator a GIN index
  # on cited_poll_ids can serve, and `[7] @> [7]` is true. The tidier-looking
  # `?|` is not an option — it only matches string elements, and these are
  # stored as JSON numbers.
  scope :citing_any, ->(poll_ids) {
    ids = Array(poll_ids).map(&:to_i).uniq
    next none if ids.empty?

    where(Array.new(ids.size, "cited_poll_ids @> ?").join(" OR "), *ids.map { |id| [ id ].to_json })
  }

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
