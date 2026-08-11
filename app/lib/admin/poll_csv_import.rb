module Admin
  # One uploaded CSV, one row through Ingest::RecordPoll each (entry_mode:
  # :csv — the same single door manual entry and the scraper use). Whole-
  # file transactionality is NOT the contract, matching the scraper's own
  # semantics: one bad row does not stop the rest of the file. The result is
  # one Row per line, carrying line number + status + reason, so the result
  # screen can show created/duplicate/invalid per row.
  #
  # Columns: race_slug (blank = generic ballot), pollster, field_start,
  # field_end, sample_size, population, sponsor, source_url, then result
  # columns dem_pct, rep_pct, optional ind_pct, other_pct, and optional
  # dem_candidate, rep_candidate, ind_candidate (matched by name within the
  # row's race — "other" has no single named candidate, so no
  # other_candidate column).
  class PollCsvImport
    STATUSES = %i[created duplicate invalid].freeze

    Row = Struct.new(:line_number, :status, :message, :poll, keyword_init: true) do
      STATUSES.each { |name| define_method(:"#{name}?") { status == name } }
    end

    RESULT_COLUMNS = {
      "dem_pct" => { party: :dem, candidate_column: "dem_candidate" },
      "rep_pct" => { party: :rep, candidate_column: "rep_candidate" },
      "ind_pct" => { party: :ind, candidate_column: "ind_candidate" },
      "other_pct" => { party: :other, candidate_column: nil }
    }.freeze

    def self.call(text)
      new(text).call
    end

    def initialize(text)
      @text = text.to_s
    end

    def call
      csv_rows = Admin::SimpleCsv.parse(@text)
      touched_race_ids = Set.new

      rows = csv_rows.each_with_index.map do |csv_row, index|
        row = process(csv_row, index + 2) # header is line 1; first data row is line 2
        touched_race_ids << row.poll.race_id if row.created? && row.poll.race_id
        row
      end

      touched_race_ids.each { |race_id| Race.find(race_id).touch }
      rows
    end

    private
      def process(csv_row, line_number)
        race, race_problem = race_for(csv_row["race_slug"])
        return Row.new(line_number: line_number, status: :invalid, message: race_problem) if race_problem

        population, population_problem = population_for(csv_row["population"])
        return Row.new(line_number: line_number, status: :invalid, message: population_problem) if population_problem

        attrs = {
          pollster_name: csv_row["pollster"], race: race,
          field_start: csv_row["field_start"].presence, field_end: csv_row["field_end"],
          sample_size: csv_row["sample_size"].presence, population: population,
          sponsor: csv_row["sponsor"], source_url: csv_row["source_url"],
          raw_payload: csv_row
        }

        outcome = Ingest::RecordPoll.call(attrs, results: results_for(csv_row, race), entry_mode: :csv)
        Row.new(line_number: line_number, status: outcome.status, message: outcome.message, poll: outcome.poll)
      end

      def race_for(slug)
        return [ nil, nil ] if slug.blank?

        race = Race.find_by(slug: slug)
        return [ nil, "unknown race_slug #{slug.inspect}" ] unless race

        [ race, nil ]
      end

      # Guarded up front rather than left to Poll's enum: an unrecognized
      # value assigned directly to an ActiveRecord enum attribute raises
      # ArgumentError, which would crash the whole import request instead of
      # rejecting one row — exactly the per-row-outcomes contract this class
      # exists to guarantee.
      def population_for(raw)
        return [ nil, nil ] if raw.blank?

        normalized = raw.to_s.strip.downcase
        return [ normalized, nil ] if Poll.populations.key?(normalized)

        [ nil, "unrecognized population #{raw.inspect} (expected one of #{Poll.populations.keys.join(', ')})" ]
      end

      def results_for(csv_row, race)
        RESULT_COLUMNS.filter_map do |column, meta|
          raw_pct = csv_row[column]
          next if raw_pct.blank?

          candidate = nil
          if race && meta[:candidate_column] && csv_row[meta[:candidate_column]].present?
            candidate = race.candidates.find_by(name: csv_row[meta[:candidate_column]])
          end

          { party: meta[:party], pct: Admin::PercentValue.parse(raw_pct), candidate: candidate }
        end
      end
  end
end
