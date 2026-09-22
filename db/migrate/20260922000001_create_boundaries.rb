class CreateBoundaries < ActiveRecord::Migration[8.1]
  def change
    create_table :boundaries do |t|
      t.string :state, null: false
      t.integer :district
      t.jsonb :geometry, null: false
      t.string :source_url, null: false
      t.timestamps
    end

    # One outline per state, one row per district. Two partial indexes
    # rather than NULLS NOT DISTINCT so the pair works on any Postgres.
    add_index :boundaries, :state, unique: true, where: "district IS NULL", name: "index_boundaries_on_state_outline"
    add_index :boundaries, [ :state, :district ], unique: true, where: "district IS NOT NULL", name: "index_boundaries_on_state_and_district"
  end
end
