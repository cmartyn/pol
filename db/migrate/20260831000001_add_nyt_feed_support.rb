class AddNytFeedSupport < ActiveRecord::Migration[8.1]
  def change
    change_table :polls, bulk: true do |t|
      t.integer :partisan, null: false, default: 0
      t.string :methodology
      t.string :nyt_poll_id
      t.string :nyt_question_id
    end
    add_index :polls, :nyt_poll_id
    add_index :polls, :nyt_question_id, unique: true

    add_column :pollsters, :nyt_pollster_id, :string
    add_index :pollsters, :nyt_pollster_id, unique: true

    add_column :forecasts, :variant, :integer, null: false, default: 0
    remove_index :forecasts, %i[model_run_id race_id], unique: true
    add_index :forecasts, %i[model_run_id race_id variant], unique: true

    add_column :chamber_forecasts, :variant, :integer, null: false, default: 0
    remove_index :chamber_forecasts, %i[model_run_id chamber], unique: true
    add_index :chamber_forecasts, %i[model_run_id chamber variant], unique: true

    create_table :feed_snapshots do |t|
      t.string :source, null: false
      t.string :digest, null: false
      t.binary :body, null: false
      t.datetime :fetched_at, null: false
      t.timestamps
    end
    add_index :feed_snapshots, %i[source digest], unique: true
  end
end
