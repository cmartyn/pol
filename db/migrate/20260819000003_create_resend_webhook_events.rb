class CreateResendWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :resend_webhook_events do |t|
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.datetime :processed_at, null: false

      t.timestamps
    end

    add_index :resend_webhook_events, :event_id, unique: true
  end
end
