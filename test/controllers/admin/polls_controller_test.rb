require "test_helper"

class Admin::PollsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  def valid_poll_params(**overrides)
    {
      race_id: races(:senate_maine).id, pollster_name: "Harbor Analytics",
      field_start: "2026-08-01", field_end: "2026-08-04", sample_size: "700", population: "lv",
      sponsor: "Portland Press", source_url: "https://example.com/harbor-1",
      results: { dem: { pct: "48.0" }, rep: { pct: "44.5" }, ind: { pct: "" }, other: { pct: "" } }
    }.merge(overrides)
  end

  # --- index ---------------------------------------------------------------

  test "index lists polls recent first" do
    get admin_polls_path
    assert_response :success
    assert_select "[data-testid='admin-poll-row']", count: Poll.count
  end

  test "index filters by race" do
    get admin_polls_path, params: { race_id: races(:senate_maine).id }
    assert_select "[data-testid='admin-poll-row']", count: races(:senate_maine).polls.count
  end

  test "index filters to generic ballot only" do
    get admin_polls_path, params: { generic_ballot_only: "1" }
    assert_select "[data-testid='admin-poll-row']", count: Poll.for_generic_ballot.count
  end

  test "index filters by entry_mode" do
    Ingest::RecordPoll.call(
      { pollster_name: "Manual Pollster", race: races(:senate_maine), field_end: Date.new(2026, 8, 1),
        source_url: "https://example.com/manual-1" },
      results: [ { party: :dem, pct: 50.0 }, { party: :rep, pct: 40.0 } ], entry_mode: :manual
    )

    get admin_polls_path, params: { entry_mode: "manual" }
    assert_select "[data-testid='admin-poll-row']", count: 1
  end

  # --- show ------------------------------------------------------------------

  test "show renders full provenance" do
    get admin_poll_path(polls(:maine_poll_one))

    assert_response :success
    assert_select "[data-testid='admin-poll-detail']"
    assert_select "[data-testid='admin-poll-digest']", text: polls(:maine_poll_one).dedup_digest
    assert_select "[data-testid='admin-poll-source-link'][href='#{polls(:maine_poll_one).source_url}']"
    assert_select "[data-testid='admin-poll-results-table']"
    assert_select "[data-testid='admin-poll-raw-payload']"
  end

  test "show renders an honest empty state for a poll with no raw_payload" do
    get admin_poll_path(polls(:maine_poll_two))
    assert_select "[data-testid='admin-poll-raw-payload-empty']"
  end

  test "show renders a non-http(s) source_url as inert text, not a clickable href" do
    polls(:maine_poll_one).update_column(:source_url, "javascript:alert(1)")

    get admin_poll_path(polls(:maine_poll_one))

    assert_select "a[data-testid='admin-poll-source-link']", count: 0
    assert_select "a[href='javascript:alert(1)']", count: 0
    assert_select "body", text: /javascript:alert\(1\)/
  end

  # --- new/create --------------------------------------------------------------

  test "new renders the form" do
    get new_admin_poll_path
    assert_response :success
    assert_select "[data-testid='admin-poll-form']"
  end

  test "create records a poll through Ingest::RecordPoll and touches the race" do
    races(:senate_maine).update_column(:updated_at, 1.day.ago)

    assert_difference "Poll.count", 1 do
      assert_difference "PollResult.count", 2 do # dem + rep in valid_poll_params; ind/other left blank
        post admin_polls_path, params: { poll: valid_poll_params }
      end
    end

    poll = Poll.order(:created_at).last
    assert_redirected_to admin_poll_path(poll)
    assert_equal "manual", poll.entry_mode
    assert_equal races(:senate_maine), poll.race
    assert poll.race.updated_at > 23.hours.ago, "race.touch must fire on admin poll create"
  end

  test "create does not touch anything for a generic-ballot poll" do
    max_before = Race.maximum(:updated_at)

    post admin_polls_path, params: { poll: valid_poll_params(race_id: "") }

    assert_equal max_before, Race.maximum(:updated_at)
  end

  test "create only records results with a non-blank percentage" do
    post admin_polls_path, params: { poll: valid_poll_params }

    poll = Poll.order(:created_at).last
    assert_equal %w[dem rep], poll.poll_results.map(&:party).sort
  end

  test "create shows a friendly duplicate error naming the existing poll, and writes nothing" do
    post admin_polls_path, params: { poll: valid_poll_params }
    first = Poll.order(:created_at).last

    assert_no_difference [ "Poll.count", "PollResult.count" ] do
      post admin_polls_path, params: { poll: valid_poll_params }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid='admin-poll-duplicate-notice'] a[href='#{admin_poll_path(first)}']"
  end

  test "create shows an inline error for invalid input and writes nothing" do
    assert_no_difference "Poll.count" do
      post admin_polls_path, params: { poll: valid_poll_params(source_url: "") }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid='admin-flash-alert']", text: /source_url/
  end

  test "create redisplays the submitted pollster name after a rejected submission" do
    post admin_polls_path, params: { poll: valid_poll_params(source_url: "") }
    assert_select "[data-testid='admin-poll-pollster-input'][value='Harbor Analytics']"
  end

  # --- edit/update -------------------------------------------------------------

  test "edit renders the form pre-filled from the existing poll" do
    get edit_admin_poll_path(polls(:maine_poll_one))

    assert_response :success
    assert_select "[data-testid='admin-poll-pollster-input'][value='#{polls(:maine_poll_one).pollster.name}']"
  end

  test "update recomputes the digest and touches the race" do
    poll = Ingest::RecordPoll.call(
      { pollster_name: "Harbor Analytics", race: races(:senate_maine), field_end: Date.new(2026, 8, 4),
        source_url: "https://example.com/harbor-1" },
      results: [ { party: :dem, pct: 48.0 }, { party: :rep, pct: 44.5 } ], entry_mode: :manual
    ).poll
    original_digest = poll.dedup_digest
    races(:senate_maine).update_column(:updated_at, 1.day.ago)

    patch admin_poll_path(poll), params: { poll: valid_poll_params(field_end: "2026-08-09") }

    assert_redirected_to admin_poll_path(poll)
    poll.reload
    assert_not_equal original_digest, poll.dedup_digest
    assert_equal Date.new(2026, 8, 9), poll.field_end
    assert poll.race.updated_at > 23.hours.ago, "race.touch must fire on admin poll edit"
  end

  test "update guards against colliding with a different existing poll" do
    poll_a = Ingest::RecordPoll.call(
      { pollster_name: "Harbor Analytics", race: races(:senate_maine), field_end: Date.new(2026, 8, 4),
        source_url: "https://example.com/harbor-1" },
      results: [ { party: :dem, pct: 48.0 }, { party: :rep, pct: 44.5 } ], entry_mode: :manual
    ).poll
    poll_b = Ingest::RecordPoll.call(
      { pollster_name: "Cardinal Research", race: races(:senate_maine), field_end: Date.new(2026, 8, 5),
        source_url: "https://example.com/cardinal-1" },
      results: [ { party: :dem, pct: 46.0 }, { party: :rep, pct: 45.0 } ], entry_mode: :manual
    ).poll

    patch admin_poll_path(poll_a), params: { poll: valid_poll_params(
      pollster_name: "Cardinal Research", field_start: "", field_end: "2026-08-05",
      results: { dem: { pct: "46.0" }, rep: { pct: "45.0" }, ind: { pct: "" }, other: { pct: "" } }
    ) }

    assert_response :unprocessable_entity
    assert_select "[data-testid='admin-poll-duplicate-notice'] a[href='#{admin_poll_path(poll_b)}']"
    assert_equal "Harbor Analytics", poll_a.reload.pollster.name
  end

  test "update destroy touches the OLD race when a poll is reassigned to another race" do
    poll = Ingest::RecordPoll.call(
      { pollster_name: "Harbor Analytics", race: races(:senate_maine), field_end: Date.new(2026, 8, 4),
        source_url: "https://example.com/harbor-1" },
      results: [ { party: :dem, pct: 48.0 }, { party: :rep, pct: 44.5 } ], entry_mode: :manual
    ).poll
    races(:senate_maine).update_column(:updated_at, 1.day.ago)
    races(:senate_florida_special).update_column(:updated_at, 1.day.ago)

    patch admin_poll_path(poll), params: { poll: valid_poll_params(race_id: races(:senate_florida_special).id) }

    assert races(:senate_maine).reload.updated_at > 23.hours.ago
    assert races(:senate_florida_special).reload.updated_at > 23.hours.ago
  end

  # --- destroy -----------------------------------------------------------------

  test "destroy deletes the poll and its results, and touches the race" do
    poll = Ingest::RecordPoll.call(
      { pollster_name: "Harbor Analytics", race: races(:senate_maine), field_end: Date.new(2026, 8, 4),
        source_url: "https://example.com/harbor-1" },
      results: [ { party: :dem, pct: 48.0 }, { party: :rep, pct: 44.5 } ], entry_mode: :manual
    ).poll
    races(:senate_maine).update_column(:updated_at, 1.day.ago)

    assert_difference "Poll.count", -1 do
      assert_difference "PollResult.count", -2 do
        delete admin_poll_path(poll)
      end
    end

    assert_redirected_to admin_polls_path
    assert races(:senate_maine).reload.updated_at > 23.hours.ago, "race.touch must fire on admin poll destroy"
  end
end
