require "csv"
require "nokogiri"

# Official Nebraska statewide export. The source's map=CTY query parameter
# does NOT turn these rows into county results: they are contest totals.
class ElectionNight::Sources::Nebraska < ElectionNight::Sources::Base
  # The export has no election-date column. These election-specific race and
  # candidate IDs were verified against the November 3, 2026 official site.
  # Pin the complete federal scaffold so an earlier election or partial CSV
  # cannot be mistaken for current results merely because it was fetched today.
  FEDERAL_CONTESTS = {
    "13224" => { key: "NE-S", area: "SW", district: "", candidates: %w[3012 3249 3434 3429 3365] },
    "13165" => { key: "NE-01", area: "CG", district: "District 01", candidates: %w[3071 3039 3202 3430] },
    "13166" => { key: "NE-02", area: "CG", district: "District 02", candidates: %w[2792 3138 3239] },
    "13167" => { key: "NE-03", area: "CG", district: "District 03", candidates: %w[2875 3055 3188 3435 3376] }
  }.freeze

  def parse(body, metadata:)
    raise InvalidData, "Nebraska 2026-only source" unless state == "NE" && election_date == "2026-11-03"
    # Collector downloads arrive as binary strings. Decode without mutating
    # archived bytes before stripping a possible Unicode BOM or parsing CSV.
    body = body.to_s.dup.force_encoding(Encoding::UTF_8)
    metadata = metadata.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidData, "invalid UTF-8 Nebraska export" unless body.valid_encoding? && metadata.valid_encoding?
    page = Nokogiri::HTML(metadata)
    identity = page.at_css("#hidElectionDate")&.[]("value")
    validate_date!(Date.strptime(identity.to_s, "%m/%d/%Y").iso8601)
    heading = page.at_css("#lnkDateHeader h2")&.text.to_s.strip
    raise InvalidData, "not the Nebraska general election" unless heading == "General Election November 3, 2026"
    raise InvalidData, "Nebraska test results" if page.at_css("#lnkDateHeader")&.text.to_s.match?(/\btest\b/i)
    # The vendor writes Excel-style ="0/1322" reporting fields and a trailing
    # empty column. Liberal parsing is necessary only for that unused field;
    # all candidate vote cells still pass the strict integer validator.
    rows = CSV.parse(body.delete_prefix("\uFEFF"), headers: true, liberal_parsing: true)
    required = %w[RaceID RaceName PartyCode AreaType AreaNum CandidateID CandidateName CurrentDateTime CandidateVotes VoteFor]
    raise InvalidData, "missing Nebraska export columns" unless (required - Array(rows.headers)).empty?

    units, candidates, export_dates = {}, Hash.new { |hash, key| hash[key] = [] }, []
    rows.each do |row|
      contest = FEDERAL_CONTESTS[row["RaceID"]]
      if !contest && row["RaceName"].to_s.match?(/United States Senator|Representative in Congress/i)
        raise InvalidData, "unknown federal contest; election manifest needs review"
      end
      next unless contest
      raise InvalidData, "unexpected Nebraska contest geography" unless row["AreaType"] == contest[:area] && row["AreaNum"].to_s == contest[:district]
      raise InvalidData, "unexpected vote-for count" unless row["VoteFor"] == "1"
      key = contest[:key]
      candidate_id = row["CandidateID"]
      raise InvalidData, "unknown or duplicate federal candidate" unless contest[:candidates].include?(candidate_id) && !candidates[key].include?(candidate_id)
      raise InvalidData, "missing candidate name or party" if row["CandidateName"].to_s.strip.empty? || row["PartyCode"].to_s.strip.empty?
      candidates[key] << candidate_id
      # CurrentDateTime is export generation time, not the last count update.
      # Keep it diagnostic only; never advertise it as fresh reported votes.
      export_dates << DateTime.strptime(row["CurrentDateTime"], "%m/%d/%Y %I:%M:%S %p")
      unit = (units[key] ||= empty_unit(key, contest[:district].empty? ? "STATEWIDE" : contest[:district]))
      add_votes(unit, row["PartyCode"], row["CandidateVotes"])
    end
    FEDERAL_CONTESTS.each_value do |contest|
      raise InvalidData, "incomplete federal candidate scaffold" unless candidates[contest[:key]].sort == contest[:candidates].sort
    end
    raise InvalidData, "export outside verified election period" unless export_dates.all? { |date| date.to_date.between?(Date.new(2026, 11, 3), Date.new(2026, 12, 31)) }
    output(units.values.map { |unit| unit.merge("geography_level" => "contest", "aggregate_only" => true) }).merge(
      "export_generated_local" => export_dates.max.strftime("%Y-%m-%dT%H:%M:%S"),
      "source_updated_local" => page.at_css("#lnkDateHeader .last-updated")&.text.to_s.strip.gsub(/\s+/, " "),
      "election_identity_method" => "official election-date metadata and pinned 2026 race and candidate IDs",
      "coverage_note" => "Official contest totals; no county breakdown. Export generation time is not a vote update timestamp."
    )
  rescue CSV::MalformedCSVError, Date::Error, TypeError, ArgumentError => error
    raise InvalidData, "invalid Nebraska results: #{error.message}"
  end
end
