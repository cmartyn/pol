require "test_helper"

class Ingest::NytSyncJobTest < ActiveJob::TestCase
  test "the cron schedule runs this job at the cadence in model_params" do
    entry = Rails.application.config.good_job.cron.fetch(:pol_nyt_sync)

    assert_equal "Ingest::NytSyncJob", entry[:class]
    assert_equal "0 */#{Pol::Params.fetch!(:feed, :cadence_hours)} * * *", entry[:cron]
    assert entry[:description].present?
  end

  test "performing the job sweeps both files and records what it found" do
    stub_request(:get, "https://www.nytimes.com/newsgraphics/polls/senate.csv")
      .to_return(status: 200, body: nyt_csv(nyt_matchup_rows))
    stub_request(:get, "https://www.nytimes.com/newsgraphics/polls/house.csv")
      .to_return(status: 200, body: nyt_csv([]))

    assert_difference "ScrapeRun.count", 2 do
      assert_difference "Poll.count", 1 do
        Ingest::NytSyncJob.perform_now
      end
    end
  end

  test "the job is enqueueable on the default queue" do
    assert_enqueued_with(job: Ingest::NytSyncJob, queue: "default") do
      Ingest::NytSyncJob.perform_later
    end
  end
end
