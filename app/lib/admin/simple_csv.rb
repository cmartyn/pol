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

    # Excel's "CSV UTF-8" export (the common Windows/Mac path for "save this
    # spreadsheet as CSV") prepends a UTF-8 byte-order-mark to announce its
    # own encoding. Left alone, that BOM byte sequence glues itself onto the
    # start of the first header's name — the header ends up as the U+FEFF
    # character followed by "race_slug", a string that is never equal to
    # the plain "race_slug" a CSV row hash is read with again. Every row's
    # race_slug lookup against that corrupted header then comes back nil,
    # and PollCsvImport's blank-means-generic-ballot rule (intentional for a
    # truly blank column) silently reassigns every named race to the
    # generic ballot instead — reported as "created", not "invalid",
    # because as far as RecordPoll can tell a generic-ballot poll was
    # exactly what was asked for.
    UTF8_BOM_BYTES = "\xEF\xBB\xBF".b.freeze

    def parse(text)
      rows = tokenize(strip_bom(text.to_s))
      return [] if rows.empty?

      headers = rows.first.map { |header| header.to_s.strip }
      rows.drop(1).map { |row| headers.each_with_index.to_h { |header, index| [ header, row[index] ] } }
    end

    # Strips a LEADING byte-order-mark only — never touches a BOM character
    # appearing anywhere else in the file (there is no global replace here,
    # only a check against the first three bytes). Works whether `text`
    # arrived already decoded as UTF-8 (the BOM is then a single character,
    # encoded as those same three bytes once reinterpreted as raw bytes) or
    # as undecoded bytes tagged ASCII-8BIT straight off an upload — both are
    # compared at the byte level so one check covers both cases.
    def strip_bom(text)
      bytes = text.b
      return text unless bytes.start_with?(UTF8_BOM_BYTES)

      bytes.byteslice(UTF8_BOM_BYTES.bytesize..).force_encoding(Encoding::UTF_8)
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
