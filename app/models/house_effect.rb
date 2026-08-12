# One pollster's estimated lean as of one model run — see
# Forecast::HouseEffects for how it is estimated and db/migrate/
# ...create_house_effects.rb for why both the raw and the shrunk value are
# kept.
#
# Sign convention, everywhere in this codebase and on the public page:
# a POSITIVE effect means the pollster's polls run more Democratic than the
# field, so the model SUBTRACTS it from the poll's D−R margin.
class HouseEffect < ApplicationRecord
  belongs_to :model_run
  belongs_to :pollster

  validates :effect_raw, :effect_shrunk, :residual_count, presence: true
  validates :residual_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  # Largest estimated lean first, whichever direction it leans.
  scope :by_magnitude, -> { order(Arel.sql("ABS(effect_shrunk) DESC"), :pollster_id) }

  # { pollster_id => effect_shrunk } for the effects a run actually applied —
  # what Forecast::Averager subtracts, and what a race page reads to show a
  # reader what was done to each poll. Empty hash for a nil run, so a site
  # with no succeeded run yet simply adjusts nothing.
  def self.applied_lookup(model_run)
    return {} if model_run.nil?

    where(model_run_id: model_run.id, applied: true).pluck(:pollster_id, :effect_shrunk).to_h
  end
end
