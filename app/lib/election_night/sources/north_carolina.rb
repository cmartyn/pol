require "csv"
require "open3"
require "tempfile"

class ElectionNight::Sources::NorthCarolina < ElectionNight::Sources::Base
  COLUMNS = [ "County", "Election Date", "Precinct", "Contest Name", "Choice", "Choice Party", "Total Votes" ].freeze
  MAX_EXPANDED_BYTES = 200 * 1024 * 1024

  def parse(body)
    parse_rows(body, presidential: false)
  end

  def parse_baselines(body)
    historical = self.class.new(state: state, election_date: "2024-11-05")
    text = historical.send(:expand, body)
    result = historical.send(:parse_rows, text, presidential: true)
    result["house_units"] = historical.send(:parse_rows, text, presidential: false, allow_empty: true)["units"].reject { |unit| unit["race_key"].end_with?("-S") }
    result
  end

  private
    def parse_rows(body, presidential:, allow_empty: false)
      # CSV.parse retains every local-contest row (hundreds of thousands of
      # fields). Read one row at a time; only federal totals and duplicate keys
      # survive. Keep the first row after reading it to establish the headers.
      rows = CSV.new(expand(body).force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF"), headers: true, col_sep: "\t")
      first_row = rows.shift
      raise InvalidData, "missing result columns" unless (COLUMNS - Array(rows.headers)).empty?
      units = {}
      seen = {}
      [ first_row ].compact.chain(rows).each do |row|
        date = Date.strptime(row.fetch("Election Date"), "%m/%d/%Y").iso8601
        validate_date!(date)
        key = race_key(row.fetch("Contest Name"), presidential: presidential)
        next unless key
        county = unit_key(row.fetch("County"))
        identity = [ county, row.fetch("Precinct"), row.fetch("Contest Name"), row.fetch("Choice"), row["Choice Party"] ]
        raise InvalidData, "duplicate candidate/precinct row" if seen[identity]
        seen[identity] = true
        unit = (units[[ key, county ]] ||= empty_unit(key, county))
        # Total Votes already includes Election Day, early, mail and provisional.
        add_votes(unit, row["Choice Party"], row.fetch("Total Votes"))
      end
      return { "units" => [] } if allow_empty && units.empty?
      output(units.values)
    rescue CSV::MalformedCSVError, Date::Error, KeyError, TypeError => error
      raise InvalidData, "invalid North Carolina results: #{error.message}"
    end

    def expand(body)
      return body.dup unless body.start_with?("PK".b)

      Tempfile.create([ "election-results-", ".zip" ]) do |file|
        file.binmode
        file.write(body)
        file.flush
        # No shell, no extraction to a filesystem path supplied by an archive.
        names, status = Open3.capture2("unzip", "-Z1", file.path)
        expected = "results_pct_#{election_date.delete('-')}.txt"
        raise InvalidData, "unexpected ZIP members" unless status.success? && names.lines.map(&:strip) == [ expected ]
        result = +"".b
        Open3.popen3("unzip", "-p", file.path, expected) do |stdin, stdout, stderr, wait|
          stdin.close
          reader = Thread.new { stderr.read }
          begin
            while (chunk = stdout.read(64 * 1024))
              result << chunk
              raise InvalidData, "expanded results exceed limit" if result.bytesize > MAX_EXPANDED_BYTES
            end
          ensure
            stdout.close
          end
          diagnostics = reader.value
          raise InvalidData, "invalid ZIP: #{diagnostics[0, 200]}" unless wait.value.success?
        end
        result
      end
    end
end
