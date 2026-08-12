class CreateHouseEffects < ActiveRecord::Migration[8.1]
  # One pollster's estimated lean, as measured by one model run. Written
  # inside the run's own transaction alongside its forecasts, so a run's
  # inputs are reproducible from its own rows rather than from whatever the
  # estimator happens to say today.
  #
  # effect_raw is the weighted mean residual; effect_shrunk is that value
  # pulled toward zero by residual_count and clamped — the number actually
  # subtracted from a poll's margin. Both are stored because the shrinkage is
  # part of what the /pollsters page has to show: a raw −6 shrunk to −1.2 on
  # two residuals is a very different claim from a raw −1.2 on forty.
  #
  # A row exists only for a pollster with at least one usable residual.
  # "No estimate" and "an estimate of zero" are different things, and a row
  # of zeroes would say the second when the first is true.
  def change
    create_table :house_effects do |t|
      t.references :model_run, null: false, foreign_key: true
      t.references :pollster, null: false, foreign_key: true
      t.float :effect_raw, null: false
      t.float :effect_shrunk, null: false
      t.integer :residual_count, null: false
      # Whether this run actually subtracted the effect. False when the
      # pollster is under house_effects.min_polls_to_apply, or when
      # house_effects.enabled is off — in both cases the estimate is still
      # published, because an adjustment a reader cannot inspect is exactly
      # what this project promised not to have.
      t.boolean :applied, null: false, default: false

      t.timestamps
    end

    add_index :house_effects, [ :model_run_id, :pollster_id ], unique: true
  end
end
