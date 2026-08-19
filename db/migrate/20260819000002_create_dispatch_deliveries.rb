class CreateDispatchDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :dispatch_deliveries do |t|
      t.references :dispatch, null: false, foreign_key: true
      t.references :subscriber, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.string :resend_email_id
      t.string :to_address
      t.string :subject
      t.text :html_body
      t.text :text_body
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :failed_at

      t.timestamps
    end

    add_index :dispatch_deliveries, [ :dispatch_id, :subscriber_id ], unique: true
    add_index :dispatch_deliveries, :resend_email_id, unique: true, where: "resend_email_id IS NOT NULL"
    add_index :dispatch_deliveries, :status
  end
end
