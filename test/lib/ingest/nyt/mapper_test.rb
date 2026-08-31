require "test_helper"

class Ingest::Nyt::MapperTest < ActiveSupport::TestCase
  setup do
    @mapper = Ingest::Nyt::Mapper.new(source: "senate.csv")
  end

  test "maps a senate general question onto the race board" do
    outcome = @mapper.map(nyt_questions(nyt_matchup_rows(
      "sponsors" => "Civic Fund", "methodology" => "Online Panel", "partisan" => "DEM"
    )).sole)

    assert outcome.mapped?
    attrs = outcome.attrs
    assert_equal races(:senate_maine), attrs[:race]
    assert_equal "Harbor Analytics", attrs[:pollster_name]
    assert_equal "pollster-uuid-1", attrs[:nyt_pollster_id]
    assert_equal Date.new(2026, 7, 8), attrs[:field_start]
    assert_equal Date.new(2026, 7, 10), attrs[:field_end]
    assert_equal 600, attrs[:sample_size]
    assert_equal :lv, attrs[:population]
    assert_equal "Civic Fund", attrs[:sponsor]
    assert_equal :dem, attrs[:partisan]
    assert_equal "Online Panel", attrs[:methodology]
    assert_equal "question-1", attrs[:nyt_question_id]
    assert_equal "question-1", attrs[:digest_salt]
    assert_equal "poll-1", attrs[:nyt_poll_id]
    assert_equal "dem:ellis|rep:rivers", attrs[:matchup_key]

    results = outcome.results
    assert_equal [ [ :dem, 48.0 ], [ :rep, 44.0 ] ], results.map { |r| [ r[:party], r[:pct] ] }
    assert_equal [ candidates(:maine_dem), candidates(:maine_rep) ], results.map { |r| r[:candidate] }
  end

  test "an unflagged poll is partisan none" do
    outcome = @mapper.map(nyt_questions(nyt_matchup_rows).sole)

    assert_equal :none, outcome.attrs[:partisan]
  end

  test "skips primaries, other cycles, and party subsamples" do
    [
      { "stage" => "primary" },
      { "cycle" => "2028" },
      { "subpopulation" => "r" }
    ].each do |overrides|
      outcome = @mapper.map(nyt_questions(nyt_matchup_rows(**overrides)).sole)

      assert outcome.skipped?, "expected #{overrides.inspect} to be skipped"
    end
  end

  test "refuses a state with no race on the board" do
    outcome = @mapper.map(nyt_questions(nyt_matchup_rows("state" => "WY")).sole)

    assert outcome.refused?
    assert_equal "unknown_race", outcome.reason
  end

  test "maps a house question by state and seat number" do
    rows = nyt_matchup_rows(
      "office_type" => "U.S. House", "state" => "NY", "seat_number" => "17",
      dem: { "candidate_name" => "Casey Nolan" },
      rep: { "candidate_name" => "Drew Halloran" }
    )
    outcome = @mapper.map(nyt_questions(rows).sole)

    assert outcome.mapped?
    assert_equal races(:house_ny_17), outcome.attrs[:race]
    assert_equal "dem:nolan|rep:halloran", outcome.attrs[:matchup_key]
  end

  test "US rows are the generic ballot: no race, no matchup" do
    rows = nyt_matchup_rows(
      "office_type" => "U.S. House", "state" => "US",
      dem: { "candidate_name" => "Democrat" },
      rep: { "candidate_name" => "Republican" }
    )
    outcome = @mapper.map(nyt_questions(rows).sole)

    assert outcome.mapped?
    assert_nil outcome.attrs[:race]
    assert_nil outcome.attrs[:matchup_key]
  end

  test "NONE rows are answers, not candidates; minor parties file under other" do
    rows = nyt_matchup_rows + [
      { "party" => "NONE", "pct" => "5", "answer" => "Don't know", "candidate_name" => "Don't know" },
      { "party" => "LIB", "pct" => "3", "answer" => "Frost", "candidate_name" => "Casey Frost" }
    ]
    outcome = @mapper.map(nyt_questions(rows).sole)

    assert_equal %i[dem rep other], outcome.results.map { |r| r[:party] }
  end

  test "where a party repeats, the first row wins — the page-column rule" do
    rows = nyt_matchup_rows + [
      { "party" => "REP", "pct" => "9", "answer" => "Second", "candidate_name" => "Riley Second" }
    ]
    outcome = @mapper.map(nyt_questions(rows).sole)

    assert_equal 44.0, outcome.results.find { |r| r[:party] == :rep }[:pct]
  end

  test "ranked-choice questions prefer the reallocated final round" do
    rows =
      nyt_matchup_rows("ranked_choice_round" => "1", "ranked_choice_final" => "FALSE",
                       dem: { "pct" => "46" }, rep: { "pct" => "41" }) +
      nyt_matchup_rows("ranked_choice_round" => "2", "ranked_choice_final" => "TRUE",
                       dem: { "pct" => "52" }, rep: { "pct" => "48" })
    outcome = @mapper.map(nyt_questions(rows).sole)

    assert_equal [ 52.0, 48.0 ], outcome.results.map { |r| r[:pct] }
  end

  test "ranked-choice questions with no final fall back to first preferences" do
    rows =
      nyt_matchup_rows("ranked_choice_round" => "1", "ranked_choice_final" => "FALSE") +
      nyt_matchup_rows("ranked_choice_round" => "2", "ranked_choice_final" => "FALSE",
                       dem: { "pct" => "50" }, rep: { "pct" => "45" })
    outcome = @mapper.map(nyt_questions(rows).sole)

    assert_equal [ 48.0, 44.0 ], outcome.results.map { |r| r[:pct] }
  end

  test "a question without a parseable end date is refused" do
    outcome = @mapper.map(nyt_questions(nyt_matchup_rows("end_date" => "")).sole)

    assert outcome.refused?
    assert_equal "missing_field_dates", outcome.reason
  end

  test "a question left with one usable side is refused" do
    outcome = @mapper.map(nyt_questions(nyt_matchup_rows(rep: { "pct" => "" })).sole)

    assert outcome.refused?
    assert_equal "too_few_parties", outcome.reason
  end

  test "feed matchup keys agree with page matchup keys for the same contest" do
    feed_key = @mapper.map(nyt_questions(nyt_matchup_rows).sole).attrs[:matchup_key]
    page_key = Ingest::Matchup.key([ "Jordan Ellis (D)", "Pat Rivers (R)" ])

    assert_equal page_key, feed_key
  end

  test "raw_payload columns take the shape the Wikipedia parser stored" do
    outcome = @mapper.map(nyt_questions(nyt_matchup_rows).sole)
    payload = outcome.attrs[:raw_payload]

    assert_equal({ "Jordan Ellis (D)" => "48", "Pat Rivers (R)" => "44" }, payload["columns"])
    assert_equal "question-1", payload["nyt"]["question_id"]
  end

  test "a mapped question round-trips through RecordPoll with a working matchup label" do
    outcome = @mapper.map(nyt_questions(nyt_matchup_rows).sole)
    result = Ingest::RecordPoll.call(outcome.attrs, results: outcome.results, entry_mode: :nyt)

    assert result.created?
    assert result.poll.nyt?
    assert_equal "Jordan Ellis (D) vs Pat Rivers (R)", result.poll.matchup_label
    assert_equal "pollster-uuid-1", result.poll.pollster.nyt_pollster_id
  end

  test "a state carrying two senate races refuses rather than guessing the seat" do
    Race.create!(office: :senate, state: "ME", cycle: 2026, special: true,
                 slug: "senate-me-2026-special", incumbent_party: :rep)
    mapper = Ingest::Nyt::Mapper.new(source: "senate.csv")

    outcome = mapper.map(nyt_questions(nyt_matchup_rows).sole)

    assert outcome.refused?
    assert_equal "ambiguous_senate_race", outcome.reason
  end

  test "a placeholder candidate in a raced question is refused at the door" do
    outcome = @mapper.map(nyt_questions(
      nyt_matchup_rows(dem: { "candidate_name" => "Generic Democrat" })
    ).sole)

    assert outcome.refused?
    assert_equal "generic_candidate", outcome.reason
  end

  test "a four-digit year refuses instead of parsing as 2020" do
    outcome = @mapper.map(nyt_questions(nyt_matchup_rows("end_date" => "7/8/2026")).sole)

    assert outcome.refused?
    assert_equal "missing_field_dates", outcome.reason
  end
end
