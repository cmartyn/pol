class CreateRaceResults < ActiveRecord::Migration[8.1]
  def change
    create_table :race_results do |t|
      t.references :race, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :votes, null: false, default: []
      t.string :returns_url
      t.datetime :reported_at
      t.datetime :checked_at
      t.jsonb :provider_call
      t.jsonb :editor_call
      t.jsonb :call_history, null: false, default: []
      t.timestamps
    end
  end
end
