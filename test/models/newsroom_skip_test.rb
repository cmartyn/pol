require "test_helper"

class NewsroomSkipTest < ActiveSupport::TestCase
  test "record! writes the row a Phase 6 admin will read" do
    skip = NewsroomSkip.record!(
      kind: :poll_reaction, race: races(:senate_maine), reason: :cap_reached, detail: "three already today"
    )

    assert_predicate skip, :poll_reaction?
    assert_predicate skip, :cap_reached?
    assert_equal races(:senate_maine), skip.race
    assert_equal "three already today", skip.detail
    assert_nil skip.payload_digest
  end

  test "a skip can belong to no race, because the brief belongs to no race" do
    assert_nil NewsroomSkip.record!(kind: :daily_brief, reason: :agents_disabled).race
  end

  test "the payload is digested, not stored" do
    payload = { kind: "poll_reaction", citable_poll_ids: [ 1, 2 ] }

    digest = NewsroomSkip.record!(kind: :poll_reaction, reason: :llm_error, payload: payload).payload_digest

    assert_equal 64, digest.length
    assert_equal digest, NewsroomSkip.record!(kind: :poll_reaction, reason: :llm_error, payload: payload)
                                     .payload_digest
    assert_not_equal digest, NewsroomSkip.record!(kind: :poll_reaction, reason: :llm_error,
                                                  payload: payload.merge(citable_poll_ids: [ 3 ])).payload_digest
  end

  test "one runaway provider message cannot fill the column" do
    skip = NewsroomSkip.record!(kind: :daily_brief, reason: :llm_error, detail: "x" * 5_000)

    assert_operator skip.detail.length, :<=, NewsroomSkip::DETAIL_LIMIT
  end

  test "every skip is logged, so a newsroom going quiet is visible in the log too" do
    log = StringIO.new
    NewsroomSkip.record!(kind: :movement_note, race: races(:senate_maine), reason: :duplicate,
                         detail: "already cited", logger: Logger.new(log))

    assert_match(/no movement_note for senate-me-2026 — duplicate: already cited/, log.string)
  end

  test "every reason the newsroom can have for not publishing is a value here" do
    assert_equal %w[validation_failed cap_reached duplicate agents_disabled no_api_key llm_error],
                 NewsroomSkip.reasons.keys
  end
end
