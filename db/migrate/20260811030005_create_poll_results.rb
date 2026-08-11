class CreatePollResults < ActiveRecord::Migration[8.1]
  def change
    create_table :poll_results do |t|
      t.references :poll, null: false, foreign_key: true
      t.references :candidate, null: true, foreign_key: true
      t.integer :party, null: false
      t.float :pct, null: false

      t.timestamps
    end
    add_index :poll_results, [ :poll_id, :party ]
  end
end
