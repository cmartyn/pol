require "test_helper"

class Ingest::ScrapeAllJobTest < ActiveJob::TestCase
  test "the cron schedule runs this job at the cadence in model_params" do
    entry = Rails.application.config.good_job.cron.fetch(:pol_scrape)

    assert_equal "Ingest::ScrapeAllJob", entry[:class]
    assert_equal "0 */#{Pol::Params.fetch!(:scrape, :cadence_hours)} * * *", entry[:cron]
    assert entry[:description].present?
  end

  test "cron is switched on, or nothing would ever run" do
    assert Rails.application.config.good_job.enable_cron
  end

  test "performing the job sweeps every source and records what it found" do
    stub_wikipedia_page("2026 United States Senate election in Maine", body: poll_page_html(rows: [
      { pollster: "Harbor Analytics", dates: "July 8–10, 2026", sample: "600 (LV)", dem: "48%", rep: "44%" }
    ]))
    stub_wikipedia_page("2026 United States Senate special election in Florida", body: poll_page_html(rows: [
      { pollster: "Sunshine Data", dates: "July 1–4, 2026", sample: "800 (RV)", dem: "45%", rep: "47%" }
    ], dem_column: "Democratic", rep_column: "Republican"))
    stub_wikipedia_page("2026 United States elections", body: poll_page_html(rows: [
      { pollster: "National Survey Co", dates: "August 1–3, 2026", sample: "1,200 (LV)", dem: "49%", rep: "43%" }
    ], dem_column: "Democratic", rep_column: "Republican"))

    assert_difference [ "ScrapeRun.count", "Poll.count" ], 3 do
      Ingest::ScrapeAllJob.perform_now
    end

    assert_equal %w[succeeded succeeded succeeded], ScrapeRun.order(:id).last(3).map(&:status)
    assert_equal [ 1, 1, 1 ], ScrapeRun.order(:id).last(3).map(&:new_count)
  end

  # The ids, not just the count: the newsroom reacts to the polls this sweep
  # created, and nothing downstream can work out which ones those were.
  test "the job hands the ids of the polls it created to the model-run seam" do
    stub_wikipedia_page("2026 United States Senate election in Maine", body: poll_page_html(rows: [
      { pollster: "Harbor Analytics", dates: "July 8–10, 2026", sample: "600 (LV)", dem: "48%", rep: "44%" }
    ]))
    stub_wikipedia_page("2026 United States Senate special election in Florida", status: 404)
    stub_wikipedia_page("2026 United States elections", body: poll_page_html(rows: [], dem_column: "Democratic", rep_column: "Republican"))

    recording(Ingest, :after_new_polls!) do |calls|
      Ingest::ScrapeAllJob.perform_now

      assert_equal [ [ [ Poll.order(:id).last.id ] ] ], calls
      assert_equal races(:senate_maine), Poll.order(:id).last.race
    end
  end

  test "the job is enqueueable on the default queue" do
    assert_enqueued_with(job: Ingest::ScrapeAllJob, queue: "default") do
      Ingest::ScrapeAllJob.perform_later
    end
  end
end
