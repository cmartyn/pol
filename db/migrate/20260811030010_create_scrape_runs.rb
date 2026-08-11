class CreateScrapeRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :scrape_runs do |t|
      t.string :source, null: false
      t.integer :status, null: false
      t.integer :fetched_count, null: false, default: 0
      t.integer :new_count, null: false, default: 0
      t.integer :duplicate_count, null: false, default: 0
      t.text :error_message
      t.datetime :started_at, null: false
      t.datetime :finished_at, null: false

      t.timestamps
    end
  end
end
