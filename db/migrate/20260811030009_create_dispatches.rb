class CreateDispatches < ActiveRecord::Migration[8.1]
  def change
    create_table :dispatches do |t|
      t.references :race, null: true, foreign_key: true
      t.integer :kind, null: false
      t.string :headline, null: false
      t.string :dek
      t.text :body_markdown, null: false
      t.jsonb :cited_poll_ids, null: false, default: []
      t.references :model_run, null: true, foreign_key: true
      t.string :model_slug
      t.integer :status, null: false
      t.datetime :published_at
      t.datetime :edited_at

      t.timestamps
    end
    add_index :dispatches, [ :status, :published_at ]
  end
end
