class ScrapeRun < ApplicationRecord
  enum :status, { succeeded: 0, failed: 1, partial: 2 }

  # Same convention as ModelRun.latest / Dispatch.recent_first — Phase 6's
  # admin is the first thing that lists ScrapeRuns back to a human, so
  # "most recent first" wasn't needed as a named scope until now.
  scope :recent_first, -> { order(finished_at: :desc, id: :desc) }
end
