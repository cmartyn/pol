class AddMatchupKeyToPolls < ActiveRecord::Migration[8.1]
  # Which contest a poll measured, normalised so two polls can be compared on
  # it: "conley vs lawler". A district's Wikipedia page publishes a general-
  # election table per plausible nominee while the primaries are unsettled —
  # Maine's 2nd carries four different Democrats against Paul LePage — and
  # nothing on the row says which one will be on the ballot. Without this
  # column the averager cannot tell that it is blending mutually exclusive
  # matchups; with it, Forecast::Averager can decline to publish an average
  # for a district whose polls disagree about who is running.
  #
  # Null for the generic ballot (its columns name no one), for polls entered
  # by hand, and for any row that named fewer than two people.
  #
  # The backfill calls Ingest::Matchup.for_poll, which rebuilds the key from
  # the cell map already stored in raw_payload. It is a one-time pass over
  # ~975 rows; nothing else in the app depends on it having run.
  def up
    add_column :polls, :matchup_key, :string
    add_index :polls, [ :race_id, :matchup_key ]

    Poll.reset_column_information
    Poll.includes(:poll_results).find_each do |poll|
      key = Ingest::Matchup.for_poll(poll)
      poll.update_column(:matchup_key, key) if key
    end
  end

  def down
    remove_index :polls, [ :race_id, :matchup_key ]
    remove_column :polls, :matchup_key
  end
end
