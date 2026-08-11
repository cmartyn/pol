class ModelRun < ApplicationRecord
  enum :status, { running: 0, succeeded: 1, failed: 2 }
  enum :trigger, { ingest: 0, manual: 1, cron: 2 }

  has_many :forecasts, dependent: :destroy
  has_many :chamber_forecasts, dependent: :destroy

  # ModelRun.succeeded.latest => succeeded runs, most recent first. Chain
  # .first to get the one run whose numbers the site should show.
  scope :latest, -> { order(started_at: :desc, id: :desc) }
end
