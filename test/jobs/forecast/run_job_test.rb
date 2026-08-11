require "test_helper"

class Forecast::RunJobTest < ActiveJob::TestCase
  test "performing the job runs the model" do
    assert_difference "ModelRun.succeeded.count", 1 do
      Forecast::RunJob.perform_now(trigger: :ingest)
    end

    run = ModelRun.latest.first
    assert_equal "ingest", run.trigger
    assert_equal Race.where(office: %i[senate house]).count, run.forecasts.count
  end

  test "the trigger defaults to ingest, which is where most runs come from" do
    Forecast::RunJob.perform_now

    assert_equal "ingest", ModelRun.latest.first.trigger
  end

  test "a run already in flight means this one steps aside" do
    ModelRun.create!(status: :running, trigger: :cron, started_at: 1.minute.ago)

    assert_no_difference "ModelRun.count" do
      assert_nil Forecast::RunJob.perform_now(trigger: :ingest)
    end
  end

  test "a run that already finished does not block the next one" do
    ModelRun.create!(status: :failed, trigger: :cron, started_at: 1.minute.ago, finished_at: 1.minute.ago)

    assert_difference "ModelRun.count", 1 do
      Forecast::RunJob.perform_now(trigger: :manual)
    end
  end

  test "the job is enqueueable on the default queue" do
    assert_enqueued_with(job: Forecast::RunJob, queue: "default") do
      Forecast::RunJob.perform_later(trigger: :cron)
    end
  end

  test "the ingest seam queues a run rather than running one inline" do
    assert_no_difference "ModelRun.count" do
      assert_enqueued_with(job: Forecast::RunJob, args: [ { trigger: :ingest } ]) do
        Ingest.after_new_polls!(7)
      end
    end
  end

  test "a scrape that found new polls ends with a forecast queued" do
    stub_wikipedia_page("2026 United States Senate election in Maine", body: poll_page_html(rows: [
      { pollster: "Harbor Analytics", dates: "July 8–10, 2026", sample: "600 (LV)", dem: "48%", rep: "44%" }
    ]))
    stub_wikipedia_page("2026 United States Senate special election in Florida", status: 404)
    stub_wikipedia_page("2026 United States elections", body: poll_page_html(rows: [], dem_column: "Democratic", rep_column: "Republican"))

    assert_enqueued_jobs 1, only: Forecast::RunJob do
      Ingest::ScrapeAllJob.perform_now
    end
  end
end
