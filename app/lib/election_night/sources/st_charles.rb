require "csv"

# The county's official LiveVoterTurnout download button exposes this CSV.
# It is only the St. Charles County portion of Missouri districts 2 and 3.
class ElectionNight::Sources::StCharles < ElectionNight::Sources::Base
  CANDIDATES = {
    "MO-02" => [ "ANN WAGNER", "FRED WELLMAN", "BRANDON COULTER DAUGHERTY", "WRITE-IN" ],
    "MO-03" => [ "BOB ONDER", "BETHANY E MANN", "JIM HIGGINS", "WRITE-IN" ]
  }.freeze

  def parse(body, metadata:)
    raise InvalidData, "St. Charles 2026-only source" unless state == "MO" && election_date == "2026-11-03"
    # Net::HTTP collector buffers are binary. The official CSV has a UTF-8
    # BOM, which must be decoded before comparing it with a Unicode prefix.
    # Keep archived bytes untouched and reject invalid text rather than scrub
    # candidate names or election identity fields.
    body = body.to_s.dup.force_encoding(Encoding::UTF_8)
    metadata = metadata.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidData, "invalid UTF-8 county export" unless body.valid_encoding? && metadata.valid_encoding?
    # Metadata is the linked election page. Its huge precinct tables are not
    # needed here; read the literal heading without constructing a DOM tree.
    heading = metadata[/<h1\b[^>]*class="election-title"[^>]*>([^<]+)<\/h1>/, 1]
    raise InvalidData, "wrong or test St. Charles election" unless heading == "November 3, 2026 General Election"
    raise InvalidData, "wrong county publisher" unless metadata.include?("St. Charles County Election Authority")
    lines = body.delete_prefix("\uFEFF").lines
    raise InvalidData, "unexpected county CSV heading" unless lines.shift.to_s.strip.match?(/\A(?:Unofficial|Official) election results\z/i) && lines.shift.to_s.strip == "St. Charles County"
    rows = CSV.parse(lines.join, headers: true)
    fields = [ "Contest Name", "Candidate Name", "Party", "Absentee Votes", "Election Day Votes", "Provisional Votes", "Total Votes" ]
    raise InvalidData, "missing county CSV columns" unless (fields - Array(rows.headers)).empty?
    units, candidates = {}, Hash.new { |hash, key| hash[key] = [] }
    rows.each do |row|
      key = race_key(row["Contest Name"])
      next unless key
      name = row["Candidate Name"]
      raise InvalidData, "unexpected or duplicate congressional candidate" unless CANDIDATES.fetch(key, []).include?(name) && !candidates[key].include?(name)
      candidates[key] << name
      total = count(row["Total Votes"])
      parts = [ "Absentee Votes", "Election Day Votes", "Provisional Votes" ].sum { |field| count(row[field]) }
      raise InvalidData, "vote methods do not reconcile" unless total == parts
      unit = (units[key] ||= empty_unit(key, "St. Charles County"))
      add_votes(unit, row["Party"], total)
    end
    CANDIDATES.each do |key, expected|
      raise InvalidData, "incomplete congressional candidate scaffold" unless candidates[key].sort == expected.sort
    end
    output(units.values).merge(
      "source_updated_local" => metadata[/id="lblLastPublishedDateTime"[^>]*>([^<]+)<\/span>/, 1],
      "coverage_note" => "Official St. Charles County portions only; not complete Missouri district totals."
    )
  rescue CSV::MalformedCSVError, TypeError, ArgumentError => error
    raise InvalidData, "invalid St. Charles results: #{error.message}"
  end
end
