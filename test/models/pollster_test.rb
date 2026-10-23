require "test_helper"

class PollsterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "exclusion requires a short reason and accepts an optional web source" do
    pollster = pollsters(:beacon_polling)
    assert_not pollster.update(excluded: true, exclusion_reason: "  ")
    assert_not pollster.reload.excluded?
    assert_not pollster.update(excluded: true, exclusion_reason: "Fabricated data", exclusion_source_url: "javascript:alert(1)")
    assert pollster.update(excluded: true, exclusion_reason: " Fabricated data ", exclusion_source_url: "https://example.com/investigation")
    assert_equal "Fabricated data", pollster.exclusion_reason
  end

  test "exclude and reinstate preserve polls and queue a refresh only when the state changes" do
    pollster = pollsters(:beacon_polling)
    race = races(:senate_maine)
    previous_touch = race.updated_at
    attributes = { excluded: true, exclusion_reason: "Withdrawn by pollster" }

    assert_no_difference [ "Poll.count", "PollResult.count", "Forecast.count", "Dispatch.count" ] do
      assert_enqueued_with(job: Forecast::RunJob, args: [ { trigger: :pollster_change } ]) { pollster.update!(attributes) }
    end
    assert_operator race.reload.updated_at, :>, previous_touch
    excluded_at = pollster.excluded_at
    assert_no_enqueued_jobs { pollster.update!(attributes) }
    assert_equal excluded_at, pollster.excluded_at
    assert_no_enqueued_jobs { pollster.update!(exclusion_reason: "Updated explanation") }

    assert_enqueued_with(job: Forecast::RunJob, args: [ { trigger: :pollster_change } ]) { pollster.update!(excluded: false) }
    assert_nil pollster.excluded_at
    assert_nil pollster.exclusion_reason
    assert_nil pollster.exclusion_source_url
    assert_includes Poll.model_corpus, polls(:maine_poll_one)
  end

  test "all current and future entry modes inherit exclusion and ingestion cannot re-enable the firm" do
    pollster = pollsters(:beacon_polling)
    pollster.update!(nyt_pollster_id: "firm-123", excluded: true, exclusion_reason: "Withdrawn")
    %i[manual csv nyt].each do |mode|
      poll = create_poll(pollster: pollster, field_end: Date.current, entry_mode: mode)
      assert_not_includes Poll.model_corpus, poll
      assert_includes Poll.from_current_sources, poll
      assert_no_enqueued_jobs { Ingest.after_new_polls!([ poll.id ]) }
    end

    outcome = Ingest::RecordPoll.call(
      { pollster_name: "Renamed Beacon", nyt_pollster_id: "firm-123", field_end: Date.current,
        source_url: "https://example.com/new-poll" },
      results: [ { party: "dem", pct: 50 }, { party: "rep", pct: 40 } ], entry_mode: :nyt
    )
    assert_predicate outcome, :created?
    assert_equal pollster.id, outcome.poll.pollster_id
    assert_predicate pollster.reload, :excluded?
    assert_not_includes Poll.model_corpus, outcome.poll
  end

  test "canonicalize lowercases and dasherizes" do
    assert_equal "data-for-progress", Pollster.canonicalize("Data For Progress")
  end

  test "canonicalize collapses punctuation and whitespace into single dashes" do
    assert_equal "data-for-progress", Pollster.canonicalize("  Data, For...  Progress!! ")
  end

  test "canonicalize strips leading and trailing dashes" do
    assert_equal "atlasintel", Pollster.canonicalize("***AtlasIntel***")
  end
end
