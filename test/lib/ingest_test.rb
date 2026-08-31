require "test_helper"

class IngestTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "after_new_polls! queues a run for corpus polls only" do
    feed = create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 7, 3),
                       race: races(:senate_maine), entry_mode: :nyt)
    scraped = create_poll(pollster: pollsters(:cardinal_research), field_end: Date.new(2026, 7, 3),
                          race: races(:senate_maine), entry_mode: :scraped)

    assert_enqueued_with(job: Forecast::RunJob, args: [ { trigger: :ingest, poll_ids: [ feed.id ] } ]) do
      Ingest.after_new_polls!([ feed.id, scraped.id ])
    end
  end

  test "a sweep that created only retired-source rows queues nothing" do
    scraped = create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 7, 3),
                          race: races(:senate_maine), entry_mode: :scraped)

    assert_no_enqueued_jobs(only: Forecast::RunJob) do
      Ingest.after_new_polls!([ scraped.id ])
    end
  end
end
