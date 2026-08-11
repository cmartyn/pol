class CreateForecasts < ActiveRecord::Migration[8.1]
  def change
    create_table :forecasts do |t|
      t.references :model_run, null: false, foreign_key: true
      t.references :race, null: false, foreign_key: true
      t.float :p_dem_win, null: false
      t.float :p_rep_win, null: false
      t.float :p_other_win, null: false, default: 0.0
      t.float :mean_margin, null: false
      t.jsonb :margin_percentiles
      t.float :effective_poll_weight, null: false, default: 0.0

      t.timestamps
    end
    add_index :forecasts, [ :model_run_id, :race_id ], unique: true
  end
end
