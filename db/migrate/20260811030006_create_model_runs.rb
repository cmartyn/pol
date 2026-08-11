class CreateModelRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :model_runs do |t|
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :status, null: false
      t.jsonb :params_snapshot
      t.bigint :rng_seed
      t.integer :trigger, null: false
      t.text :error_message

      t.timestamps
    end
    add_index :model_runs, [ :status, :started_at ]
  end
end
