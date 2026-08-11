class CreateChamberForecasts < ActiveRecord::Migration[8.1]
  def change
    create_table :chamber_forecasts do |t|
      t.references :model_run, null: false, foreign_key: true
      t.integer :chamber, null: false
      t.float :p_dem_control, null: false
      t.float :p_rep_control, null: false
      t.float :mean_dem_seats, null: false
      t.jsonb :seat_histogram

      t.timestamps
    end
    add_index :chamber_forecasts, [ :model_run_id, :chamber ], unique: true
  end
end
