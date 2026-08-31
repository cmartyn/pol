require "csv"

# Builds NYT poll-CSV bodies for tests. The header is the feed's real 49
# columns as observed August 2026, so a test names only the fields it is
# about and everything else arrives shaped like the wire. The live-schema
# check is the backfill itself; these keep the unit tests honest and local.
module NytCsvHelper
  NYT_HEADERS = %w[
    poll_id pollster_id pollster sponsor_ids sponsors display_name
    pollster_rating_id pollster_rating_name numeric_grade pollscore
    methodology transparency_score state start_date end_date
    sponsor_candidate_id sponsor_candidate sponsor_candidate_party
    question_id sample_size population subpopulation population_full tracking
    created_at notes url url_article url_topline url_crosstab source internal
    partisan cycle office_type seat_name seat_number election_date stage
    party pct answer candidate_name candidate_id race_id ranked_choice_round
    ranked_choice_reallocated ranked_choice_final nationwide_match hypothetical
  ].freeze

  NYT_ROW_DEFAULTS = {
    "poll_id" => "poll-1",
    "pollster_id" => "pollster-uuid-1",
    "pollster" => "Harbor Analytics",
    "display_name" => "Harbor Analytics",
    "state" => "ME",
    "start_date" => "7/8/26",
    "end_date" => "7/10/26",
    "question_id" => "question-1",
    "sample_size" => "600",
    "population" => "lv",
    "url" => "https://example.com/poll",
    "cycle" => "2026",
    "office_type" => "U.S. Senate",
    "election_date" => "2026-11-03",
    "stage" => "general"
  }.freeze

  def nyt_csv(rows)
    CSV.generate(headers: NYT_HEADERS, write_headers: true, force_quotes: true) do |csv|
      rows.each { |row| csv << NYT_ROW_DEFAULTS.merge(row.stringify_keys).values_at(*NYT_HEADERS) }
    end
  end

  # The two answer rows every simple matchup question needs. String-keyed
  # overrides apply to both rows (question_id, state, dates…); dem:/rep:
  # apply per side.
  def nyt_matchup_rows(dem: {}, rep: {}, **shared)
    shared = shared.stringify_keys
    [
      { "party" => "DEM", "pct" => "48", "answer" => "Ellis", "candidate_name" => "Jordan Ellis" }.merge(shared).merge(dem.stringify_keys),
      { "party" => "REP", "pct" => "44", "answer" => "Rivers", "candidate_name" => "Pat Rivers" }.merge(shared).merge(rep.stringify_keys)
    ]
  end

  def nyt_questions(rows)
    Ingest::Nyt::CsvParser.new.parse(nyt_csv(rows))
  end
end
