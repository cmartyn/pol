class AddRefusalsToScrapeRuns < ActiveRecord::Migration[8.1]
  # Until now "succeeded, fetched 0" meant two different things — the page has
  # no polling section, or the parser looked at a polling table and refused it
  # — and nothing on the row told them apart, so a race could go dark without
  # anyone noticing. These two columns are the difference.
  #
  # refused_count is how many tables were turned down; refusal_reasons maps a
  # machine-readable reason to how many times it fired:
  #
  #   { "primary_only_table" => 5, "no_candidate_column_match" => 8 }
  #
  # The one reason that is not a table is `no_polling_section`: it says the
  # page had no polling section to read, so it is recorded as a reason while
  # refused_count stays at zero. "succeeded, fetched 0, refused 0, reason
  # no_polling_section" and "partial, fetched 0, refused 1, reason
  # primary_only_table" are the two cases that used to be one.
  def change
    add_column :scrape_runs, :refused_count, :integer, default: 0, null: false
    add_column :scrape_runs, :refusal_reasons, :jsonb, default: {}, null: false
  end
end
