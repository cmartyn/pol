require "test_helper"

class Ingest::Nyt::ReprocessTest < ActiveSupport::TestCase
  test "repairs stored rows in place, preserves provenance, and is idempotent" do
    rows = nyt_questions(nyt_matchup_rows + [
      { "party" => "REP", "pct" => "1", "candidate_name" => "Riley Second", "candidate_id" => "minor" }
    ]).sole.rows
    poll = create_poll(pollster: pollsters(:beacon_polling), race: races(:senate_maine),
      field_end: Date.new(2026, 7, 10), results: { dem: 48.0, rep: 1.0 },
      matchup_key: "dem:ellis|rep:second", raw_payload: {
        "editor_note" => "Retain this", "columns" => { "Riley Second (R)" => "1" },
        "nyt" => { "rows" => rows, "question_id" => "repair-question" }
      })
    poll.update!(entry_mode: :nyt, nyt_question_id: "repair-question", nyt_poll_id: "poll-1")
    created_at = poll.created_at
    repair = Ingest::Nyt::Reprocess.new(scope: Poll.where(id: poll.id))

    assert_equal 1, repair.call[:changed]
    assert_equal 2, poll.poll_results.count
    assert_equal 1, repair.call(apply: true)[:changed]
    poll.reload
    assert_equal created_at, poll.created_at
    assert_equal "dem:ellis|rep:rivers", poll.matchup_key
    assert_equal 3, poll.poll_results.count
    assert_equal 44.0, poll.leading_result(:rep).pct
    assert_equal "Retain this", poll.raw_payload["editor_note"]
    refute_includes poll.raw_payload["columns"].keys, "Riley Second (R)"
    assert_equal rows, poll.raw_payload.dig("nyt", "rows")
    assert_equal 0, repair.call(apply: true)[:changed]
  end

  test "an unmappable source rolls back the entire repair" do
    poll = polls(:maine_poll_one)
    poll.update!(entry_mode: :nyt, nyt_question_id: "no-source")
    before = poll.attributes

    assert_raises(RuntimeError) { Ingest::Nyt::Reprocess.new(scope: Poll.where(id: poll.id)).call(apply: true) }
    assert_equal before, poll.reload.attributes
  end
end
