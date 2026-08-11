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
  #
  # The OR is assembled by Active Record (`reduce(:or)`) rather than by joining
  # a condition string n times, so no SQL fragment here is ever built from a
  # value: every clause is the same frozen literal with one bound parameter.
  # The joined-string version was equally safe — the ids were `to_i`'d and the
  # values bound — but Brakeman cannot see that a string built at runtime
  # contains only literal text, and it reported it as possible SQL injection
  # (Phase 5's one standing warning). Making the safety structural rather than
  # argued is cheaper than carrying a suppression.
  scope :citing_any, ->(poll_ids) {
    ids = Array(poll_ids).map(&:to_i).uniq
    next none if ids.empty?

    ids.map { |id| where("cited_poll_ids @> ?", [ id ].to_json) }.reduce(:or)
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
