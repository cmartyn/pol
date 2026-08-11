class Forecast < ApplicationRecord
  belongs_to :model_run
  belongs_to :race

  # Forecasts belonging to the most recently *succeeded* model run — the
  # numbers the public site should actually display. A subquery rather than
  # two round-trips, so it stays a single query no matter how many races are
  # on the page (Phase 4 should call this once per page, not per race).
  def self.latest_for_races
    where(model_run_id: ModelRun.succeeded.latest.limit(1).select(:id))
  end
end
