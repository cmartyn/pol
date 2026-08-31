require "test_helper"

class Ingest::ScrapeAllJobTest < ActiveJob::TestCase
  test "the cron schedule runs the fallback canary weekly, dry" do
    entry = Rails.application.config.good_job.cron.fetch(:pol_scrape)

    assert_equal "Ingest::ScrapeAllJob", entry[:class]
    assert_equal "0 6 * * 0 America/New_York", entry[:cron]
    assert entry[:description].present?
    assert_not Pol::Params.fetch!(:scrape, :write_enabled),
               "the production sweep must be dry while the NYT feed is the corpus"
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
    # The fixture world's one House district makes New York a fourth source.
    stub_district_pages

    assert_difference "ScrapeRun.count", 4 do
      assert_no_difference "Poll.count" do
        Ingest::ScrapeAllJob.perform_now
      end
    end

    assert_equal %w[succeeded succeeded succeeded succeeded], ScrapeRun.order(:id).last(4).map(&:status)
    # Dry: new_count is what a live sweep would have created, with no row written.
    assert_equal [ 1, 1, 1, 0 ], ScrapeRun.order(:id).last(4).map(&:new_count)
  end

  # A dry sweep creates nothing, so nothing reaches the model-run seam — the
  # newsroom can never react to a poll the canary merely counted.
  test "the job hands nothing to the model-run seam while the sweep is dry" do
    stub_wikipedia_page("2026 United States Senate election in Maine", body: poll_page_html(rows: [
      { pollster: "Harbor Analytics", dates: "July 8–10, 2026", sample: "600 (LV)", dem: "48%", rep: "44%" }
    ]))
    stub_wikipedia_page("2026 United States Senate special election in Florida", status: 404)
    stub_wikipedia_page("2026 United States elections", body: poll_page_html(rows: [], dem_column: "Democratic", rep_column: "Republican"))
    stub_district_pages

    recording(Ingest, :after_new_polls!) do |calls|
      assert_no_difference "Poll.count" do
        Ingest::ScrapeAllJob.perform_now
      end

      assert_empty calls
    end
  end

  test "the job is enqueueable on the default queue" do
    assert_enqueued_with(job: Ingest::ScrapeAllJob, queue: "default") do
      Ingest::ScrapeAllJob.perform_later
    end
  end
end
