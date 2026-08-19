class CreateSubscribers < ActiveRecord::Migration[8.1]
  def change
    create_table :subscribers do |t|
      t.string :email_address, null: false
      t.integer :status, null: false, default: 0
      t.string :source
      t.datetime :subscribed_at, null: false
      t.datetime :unsubscribed_at
      t.string :suppression_reason
      t.datetime :last_resend_event_at
      t.integer :token_version, null: false, default: 1

      t.timestamps
    end

    add_index :subscribers, "lower(email_address)", unique: true, name: "index_subscribers_on_lower_email_address"
    add_index :subscribers, :status
  end
end
