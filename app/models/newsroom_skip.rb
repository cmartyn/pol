# One piece the newsroom decided not to publish, and why. See
# db/migrate/20260811050001_create_newsroom_skips.rb for the reasoning.
class NewsroomSkip < ApplicationRecord
  # Mirrors Dispatch's kinds: a skip is a dispatch that didn't happen.
  enum :kind, { poll_reaction: 0, movement_note: 1, daily_brief: 2 }

  enum :reason, {
    validation_failed: 0,
    cap_reached: 1,
    duplicate: 2,
    agents_disabled: 3,
    no_api_key: 4,
    llm_error: 5
  }

  belongs_to :race, optional: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  DETAIL_LIMIT = 1000

  class << self
    # The one way a skip gets written, so every one of them is also logged and
    # nothing can record a skip silently. `payload` is the context the writer
    # was working from; only its digest is stored.
    def record!(kind:, reason:, race: nil, detail: nil, payload: nil, logger: Rails.logger)
      skip = create!(
        kind: kind,
        race: race,
        reason: reason,
        detail: detail&.to_s&.truncate(DETAIL_LIMIT),
        payload_digest: payload && digest_for(payload)
      )

      logger.info("Newsroom: no #{kind}#{race ? " for #{race.slug}" : ''} — #{reason}: #{detail}")
      skip
    end

    def digest_for(payload)
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end
  end
end
