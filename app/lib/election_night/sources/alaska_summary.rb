require "open3"
require "tempfile"

class ElectionNight::Sources::AlaskaSummary < ElectionNight::Sources::Base
  def parse(body)
    raise InvalidData, "Alaska-only source" unless state == "AK"
    raise InvalidData, "expected bounded PDF" unless body.start_with?("%PDF-") && body.bytesize <= 10 * 1024 * 1024
    Tempfile.create([ "alaska-summary-", ".pdf" ]) do |file|
      file.binmode
      file.write(body)
      file.flush
      # Read the first two pages only. Both federal contests must be present;
      # a changed layout fails closed instead of guessing from other races.
      text, status = Open3.capture2e("pdftotext", "-layout", "-f", "1", "-l", "2", file.path, "-")
      raise InvalidData, "PDF extraction failed" unless status.success? && text.bytesize <= 1_000_000
      parse_text(text)
    end
  rescue Errno::ENOENT => error
    raise InvalidData, "PDF extraction requires pdftotext: #{error.message}"
  end

  private
    def parse_text(text)
      raise InvalidData, "unexpected Alaska report" unless text.include?("State of Alaska") && text.include?("GENERAL ELECTION") && text.include?("UNOFFICIAL RESULTS")
      raise InvalidData, "test election" if text.match?(/\b(?:TEST|SAMPLE|REHEARSAL)\b/)
      date = text.match(/^\s*([A-Z][a-z]+ \d{1,2}, \d{4})\s*$/)
      raise InvalidData, "missing election date" unless date
      validate_date!(Date.strptime(date[1], "%B %d, %Y").iso8601)
      units = { "Senator" => "AK-S", "Representative" => "AK-AL" }.map do |office, key|
        blocks = text.scan(/^U\.S\. #{office}\s*\n(.*?)(?=^U\.S\.|\f|\z)/m)
        raise InvalidData, "missing or duplicate federal contest" unless blocks.length == 1
        table = blocks.first.first.match(/^Candidate\s+Party\s+Total\s*\n(.*?)^Total Votes\s+([\d,]+)\s*$/m)
        raise InvalidData, "missing candidate table or total" unless table
        unit = empty_unit(key, "STATEWIDE")
        names = []
        table[1].lines.reject { |line| line.strip.empty? }.each do |line|
          row = line.strip.match(/\A(.+?)\s{2,}(?:([A-Z]{2,4})\s+)?([\d,]+)\s+(?:N\/A|\d+(?:\.\d+)?%)\z/)
          raise InvalidData, "unrecognized candidate row" unless row
          raise InvalidData, "duplicate candidate" if names.include?(row[1])
          names << row[1]
          add_votes(unit, row[2], integer_text(row[3]))
        end
        raise InvalidData, "empty candidate table" if names.empty?
        raise InvalidData, "candidate sum differs from total" unless unit["total_votes"] == count(integer_text(table[2]))
        unit.merge("aggregate_only" => true, "geography_level" => "contest", "first_choice_only" => true)
      end
      result = output(units)
      result["coverage_note"] = "Official statewide first-choice totals only; ranked-choice transfers are not represented."
      result
    rescue Date::Error => error
      raise InvalidData, "invalid Alaska election date: #{error.message}"
    end

    def integer_text(value)
      raise InvalidData, "invalid vote count" unless value.match?(/\A(?:\d+|\d{1,3}(?:,\d{3})+)\z/)
      value.delete(",")
    end
end
