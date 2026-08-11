class CreateRaces < ActiveRecord::Migration[8.1]
  def change
    create_table :races do |t|
      t.integer :office, null: false
      t.string :state, null: false
      t.integer :district
      t.integer :cycle, null: false, default: 2026
      t.integer :seat_class
      t.boolean :special, null: false, default: false
      t.string :slug, null: false
      t.string :incumbent_name
      t.integer :incumbent_party
      t.boolean :open_seat, null: false, default: false
      t.float :baseline_margin
      t.string :baseline_source_url
      t.boolean :baseline_imputed, null: false, default: false
      t.float :lean
      t.boolean :uncontested, null: false, default: false
      t.integer :uncontested_party

      t.timestamps
    end
    add_index :races, :slug, unique: true
    add_index :races, :office
  end
end
