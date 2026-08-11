class CreateNewsroomSkips < ActiveRecord::Migration[8.1]
  # The newsroom publishes without an approval queue, so the only record of a
  # piece that was *not* written is the one we keep ourselves. Every non-publish
  # outcome — kill switch, missing key, a cap, a duplicate, a draft our
  # validator rejected twice, an API failure — lands here, and Phase 6's admin
  # lists them. Without this table an autonomous newsroom that quietly stops
  # writing looks exactly like a newsroom with nothing to say.
  def change
    create_table :newsroom_skips do |t|
      t.integer :kind, null: false
      t.references :race, null: true, foreign_key: true
      t.integer :reason, null: false
      t.text :detail
      # SHA256 of the context payload the writer was working from, so two
      # skips can be told apart (or recognised as the same attempt retried)
      # without storing the payload itself.
      t.string :payload_digest

      t.timestamps
    end

    add_index :newsroom_skips, [ :reason, :created_at ]
    add_index :newsroom_skips, :created_at
  end
end
