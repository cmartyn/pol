class Forecast < ApplicationRecord
  # Which corpus this row was computed from: the default excludes
  # partisan-sponsored polls; the alternate includes them, adjusted and
  # down-weighted. One model run writes both; readers default to
  # excl_internals so an unthreaded call site keeps today's behaviour.
  enum :variant, { excl_internals: 0, incl_internals: 1 }, default: :excl_internals

  belongs_to :model_run
  belongs_to :race

  # Most competitive races first: the forecasts whose Democratic win
  # probability sits closest to a coin flip. Arel.sql marks the ABS()
  # expression as trusted, which Rails requires for a non-column ORDER BY.
  scope :by_competitiveness, -> { order(Arel.sql("ABS(p_dem_win - 0.5)"), :race_id) }

  # Forecasts belonging to the most recently *succeeded* model run — the
  # numbers the public site should actually display. A subquery rather than
  # two round-trips, so it stays a single query no matter how many races are
  # on the page (Phase 4 should call this once per page, not per race).
  # Defaults to the published variant; a caller after the internals view says
  # so explicitly.
  def self.latest_for_races(variant: :excl_internals)
    where(variant: variant, model_run_id: ModelRun.succeeded.latest.limit(1).select(:id))
  end
end
