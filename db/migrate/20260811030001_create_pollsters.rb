class CreatePollsters < ActiveRecord::Migration[8.1]
  def change
    create_table :pollsters do |t|
      t.string :name, null: false
      t.string :slug, null: false

      t.timestamps
    end
    add_index :pollsters, :slug, unique: true
  end
end
