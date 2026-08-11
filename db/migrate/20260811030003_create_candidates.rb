class CreateCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :candidates do |t|
      t.references :race, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :party, null: false
      t.integer :caucus_with
      t.boolean :incumbent, null: false, default: false

      t.timestamps
    end
    add_index :candidates, [ :race_id, :party ]
  end
end
