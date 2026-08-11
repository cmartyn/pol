class CreatePolls < ActiveRecord::Migration[8.1]
  def change
    create_table :polls do |t|
      t.references :pollster, null: false, foreign_key: true
      t.references :race, null: true, foreign_key: true
      t.date :field_start
      t.date :field_end, null: false
      t.integer :sample_size
      t.integer :population, null: false, default: 3
      t.string :sponsor
      t.string :source_url, null: false
      t.string :dedup_digest, null: false
      t.integer :entry_mode, null: false
      t.jsonb :raw_payload

      t.timestamps
    end
    add_index :polls, :dedup_digest, unique: true
    add_index :polls, :field_end
  end
end
