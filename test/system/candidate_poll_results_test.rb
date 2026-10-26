require "application_system_test_case"

class CandidatePollResultsTest < ApplicationSystemTestCase
  test "same-party candidates and ranked-choice rounds remain distinct on mobile" do
    race = races(:senate_maine)
    race.polls.destroy_all
    candidates(:maine_rep).update!(name: "Dan Sullivan")
    rows = nyt_matchup_rows("ranked_choice_round" => "1", "ranked_choice_final" => "FALSE",
      "end_date" => Date.current.strftime("%-m/%-d/%y"), "start_date" => Date.current.strftime("%-m/%-d/%y"),
      dem: { "pct" => "47", "candidate_id" => "democrat" },
      rep: { "pct" => "44", "candidate_name" => "Dan Sullivan", "candidate_id" => "incumbent" }) + [
      { "party" => "REP", "pct" => "4", "candidate_name" => "Dan J. Sullivan", "candidate_id" => "challenger" },
      { "party" => "REP", "pct" => "1", "candidate_name" => "Gerald Heikes", "candidate_id" => "minor" }
    ]
    rows.each { |row| row.merge!("ranked_choice_round" => "1", "ranked_choice_final" => "FALSE") }
    outcome = Ingest::Nyt::Mapper.new(source: "senate.csv").map(nyt_questions(rows).sole)
    record = Ingest::RecordPoll.call(outcome.attrs, results: outcome.results, entry_mode: :nyt)
    assert record.created?
    Forecast::Runner.call(trigger: :manual, as_of: Date.current, seed: 42, n_sims: 1000)

    page.current_window.resize_to(375, 812)
    visit race_path(race.slug)
    within "[data-testid='poll-row']" do
      assert_text "Dan Sullivan 44.0%"
      assert_text "Dan J. Sullivan 4.0%"
      assert_text "Gerald Heikes 1.0%"
      assert_text "D+3.0"
      assert_text "Ranked-choice round 1"
    end
    assert_no_selector "[data-testid='ambiguous-matchup-note']"
    assert_no_selector "[data-testid='earlier-matchup-tag']"
    assert_selector "[data-testid='polling-correction-note']"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  end
end
