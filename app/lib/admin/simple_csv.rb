module Admin
  # A minimal, hand-rolled CSV reader for the poll-import form
  # (Admin::PollCsvImport) — not the "csv" stdlib gem. As of Ruby 3.4, "csv"
  # is a bundled (not default) gem; on the Ruby this app runs, it is not in
  # the resolved Gemfile.lock (`require "csv"` raises LoadError even under
  # `bundle exec`, verified directly), and adding it would be a new
  # dependency, which this phase's brief rules out. This parser covers
  # exactly the RFC 4180 subset an admin-authored spreadsheet export needs:
  # comma-separated fields and double-quoted fields that may contain commas
  # or newlines. It does NOT support "" as an escaped literal quote inside a
  # quoted field — pollster/sponsor names and URLs don't contain literal
  # quote characters in practice, and that is the one corner deliberately
  # left uncovered.
  #
  #   Admin::SimpleCsv.parse("a,b\n1,2\n") # => [ { "a" => "1", "b" => "2" } ]
  #
  # The first row is always the header (whitespace-trimmed). Rows are plain
  # Hashes keyed by header, not CSV::Row. A short row (fewer fields than
  # headers) fills the missing keys with nil rather than raising — a
  # ragged hand-edited spreadsheet is exactly the input this exists to be
  # forgiving of. Blank lines are skipped.
  module SimpleCsv
    module_function

    def parse(text)
      rows = tokenize(text.to_s)
      return [] if rows.empty?

      headers = rows.first.map { |header| header.to_s.strip }
      rows.drop(1).map { |row| headers.each_with_index.to_h { |header, index| [ header, row[index] ] } }
    end

    def tokenize(text)
      rows = []
      row = []
      field = +""
      in_quotes = false

      text.delete("\r").each_char do |char|
        if in_quotes
          if char == '"'
            in_quotes = false
          else
            field << char
          end
        elsif char == '"' && field.empty?
          in_quotes = true
        elsif char == ","
          row << field
          field = +""
        elsif char == "\n"
          row << field
          rows << row
          row = []
          field = +""
        else
          field << char
        end
      end
      row << field unless field.empty? && row.empty?
      rows << row unless row.empty?

      rows.reject { |candidate_row| candidate_row.length == 1 && candidate_row.first.to_s.empty? }
    end
  end
end
