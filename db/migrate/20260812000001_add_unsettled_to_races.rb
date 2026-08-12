class AddUnsettledToRaces < ActiveRecord::Migration[8.1]
  # `unsettled` used to be documentation-only inside db/seed_data/
  # senate_2026.yml: real information for a human reading the file, invisible
  # to the app and to the public site. This persists it on the Race so the
  # methodology page can say how many Senate races are currently running on a
  # declared front-runner rather than a confirmed nominee, read live instead
  # of hardcoded.
  #
  # Backfilled here rather than left for the next `pol:seed_races` run — the
  # same choice AddMatchupKeyToPolls made — so the column is correct the
  # moment this migration finishes rather than only after someone next
  # re-seeds. Matches on (office, cycle, state, special) instead of
  # reconstructing SeedRaces#senate_slug, since that is a one-line change if
  # the slug format ever does. Calling app code (Race, Ingest::Sources) from
  # a migration is an established pattern here — see AddMatchupKeyToPolls.
  def up
    add_column :races, :unsettled, :boolean, default: false, null: false
    Race.reset_column_information

    cycle = Ingest::Sources.cycle
    YAML.safe_load_file(Rails.root.join("db/seed_data/senate_2026.yml")).each do |entry|
      next unless entry["unsettled"]

      Race.senate.where(cycle: cycle, state: entry.fetch("state"), special: entry.fetch("special", false))
          .update_all(unsettled: true)
    end
  end

  def down
    remove_column :races, :unsettled
  end
end
