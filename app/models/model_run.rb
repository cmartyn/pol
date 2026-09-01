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

  # The sponsor-lean discount this run applied to its incl_internals variant,
  # recorded in params_snapshot by Forecast::Runner. Falls back to the prior
  # for runs from before the dual-variant model — the number a live adjusted
  # average should use when this run is the one on show.
  def internals_shift
    params_snapshot&.dig("internals_estimate", "shift") ||
      Pol::Params.fetch!(:internals, :prior_shift).to_f
  end

  # How many simulated elections this run actually drew, from its own
  # params_snapshot — the denominator the site prints beside its
  # probabilities (Site::Format.of_simulations).
  #
  # Read from the run, never from Pol::Params, and that distinction is the
  # whole reason this exists. Raising simulation.n_sims does not recompute
  # the forecasts already in the table, so between the deploy and the next
  # run the site is showing rows drawn at the old count. Sourcing the
  # denominator from the live config would relabel those rows as a fraction
  # of a number of worlds that were never simulated — which is exactly the
  # false claim the phrasing change was made to stop. Falls back to the
  # current parameter only for runs from before the snapshot carried it.
  def n_sims
    params_snapshot&.dig("simulation", "n_sims") || Pol::Params.fetch!(:simulation, :n_sims)
  end

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
