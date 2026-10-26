class PreservePollCandidateIdentity < ActiveRecord::Migration[8.1]
  def change
    add_column :poll_results, :candidate_name, :string
    add_column :poll_results, :source_candidate_id, :string
  end
end
