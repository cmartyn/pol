class ModelRun < ApplicationRecord
  enum :status, { running: 0, succeeded: 1, failed: 2 }
  enum :trigger, { ingest: 0, manual: 1, cron: 2 }

  has_many :forecasts, dependent: :destroy
  has_many :chamber_forecasts, dependent: :destroy
  # The pollster leans this run estimated and (where they cleared the minimum
  # poll count) subtracted — see Forecast::HouseEffects.
  has_many :house_effects, dependent: :destroy

  # ModelRun.succeeded.latest => succeeded runs, most recent first. Chain
  # .first to get the one run whose numbers the site should show.
  scope :latest, -> { order(started_at: :desc, id: :desc) }

  class << self
    # The succeeded run to compare `run` against for "what changed in the last
    # week": the one closest to window_days before it — closest, not "within",
    # because run history is short (a handful of runs) and a comparison that
    # returns nothing is worse than one that reaches a little further than
    # asked. An in-memory scan of the succeeded runs, which needs no
    # database-specific date arithmetic and does not scale with the number of
    # races. Both the dashboard's movers module (Site::Movers) and the
    # newsroom's movement notes select their comparison run here, so the two
    # can never disagree about which run "last week" means.
    def comparison_run(run, window_days:)
      target = run.started_at - window_days.days
      candidates = succeeded.where.not(id: run.id).to_a
      return nil if candidates.empty?

      candidates.min_by { |candidate| (candidate.started_at - target).abs }
    end

    # The succeeded run immediately before this one — "where the forecast
    # stood before these polls landed".
    def previous_succeeded(run)
      return nil unless run&.started_at

      succeeded.where.not(id: run.id).where(started_at: ...run.started_at).latest.first
    end
  end
end
