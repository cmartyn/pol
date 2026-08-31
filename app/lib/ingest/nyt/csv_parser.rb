require "csv"

module Ingest
  module Nyt
    # Turns one NYT poll CSV into question groups. The file is long-form —
    # one row per candidate-answer — and the unit our tables want is the
    # question: one matchup asked of one sample, which is exactly what a
    # `polls` row is. A poll (poll_id) asking three hypothetical matchups is
    # three questions and will become three rows, matching the grain the
    # Wikipedia parser produced from three table rows.
    class CsvParser
      ParseFailed = Class.new(StandardError)

      Question = Struct.new(:question_id, :rows, keyword_init: true) do
        # Poll-level fields repeat identically on every row of a question;
        # read them off the first.
        def poll_field(name) = rows.first[name]
      end

      # Ordered as encountered, so ingestion order is the file's order and a
      # re-run walks rows the same way.
      def parse(body)
        table = CSV.parse(body, headers: true, encoding: Encoding::UTF_8)
        grouped = table.each_with_object({}) do |row, groups|
          id = row["question_id"].to_s
          next if id.blank?

          (groups[id] ||= []) << row.to_h
        end

        grouped.map { |id, rows| Question.new(question_id: id, rows: rows) }
      rescue CSV::MalformedCSVError => error
        raise ParseFailed, "malformed CSV: #{error.message}"
      end
    end
  end
end
