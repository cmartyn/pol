class AddExclusionToPollsters < ActiveRecord::Migration[8.1]
  def change
    add_column :pollsters, :excluded_at, :datetime
    add_column :pollsters, :exclusion_reason, :text
    add_column :pollsters, :exclusion_source_url, :string
  end
end
