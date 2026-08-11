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

  # Stepping aside is not a failure. If it raised, good_job would retry it and
  # the queue would fill with jobs fighting over a run that is already going.
  test "stepping aside does not surface as a job failure" do
    ModelRun.create!(status: :running, trigger: :cron, started_at: 1.minute.ago)

    assert_nothing_raised { Forecast::RunJob.perform_now(trigger: :ingest) }
  end

  # The scenario that used to freeze the forecast permanently: a worker killed
  # mid-run leaves a `running` row with no finished_at, and every later job
  # steps aside forever while the site serves stale numbers.
  test "a run abandoned by a killed worker is failed and the next run takes over" do
    abandoned = ModelRun.create!(
      status: :running, trigger: :ingest,
      started_at: (Pol::Params.fetch!(:simulation, :stale_run_minutes) + 1).minutes.ago
    )

    assert_difference "ModelRun.succeeded.count", 1 do
      Forecast::RunJob.perform_now(trigger: :cron)
    end

    abandoned.reload
    assert_predicate abandoned, :failed?
    assert_match(/abandoned/, abandoned.error_message)
    assert_not_nil abandoned.finished_at
  end

  test "a run that is merely slow is left alone" do
    slow = ModelRun.create!(
      status: :running, trigger: :ingest,
      started_at: (Pol::Params.fetch!(:simulation, :stale_run_minutes) - 1).minutes.ago
    )

    assert_no_difference "ModelRun.count" do
      assert_nil Forecast::RunJob.perform_now(trigger: :ingest)
    end

    assert_predicate slow.reload, :running?
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

  test "the cron schedule runs the model every morning half an hour before the brief" do
    entry = Rails.application.config.good_job.cron.fetch(:pol_daily_model)

    assert_equal "Forecast::RunJob", entry[:class]
    assert_equal "30 6 * * * America/New_York", entry[:cron]
    assert_equal({ trigger: :cron }, entry[:kwargs])
    assert entry[:description].present?
  end

  # Ingest queues a run whenever polls arrive, so before this entry existed a
  # day with no new polling was a day the forecast never re-ran — the numbers
  # sat still while their "as of" timestamp aged.
  test "the daily model run is scheduled before the daily brief, so the brief has fresh numbers" do
    cron = Rails.application.config.good_job.cron
    model = Fugit.parse_cron(cron.fetch(:pol_daily_model)[:cron])
    brief = Fugit.parse_cron(cron.fetch(:pol_daily_brief)[:cron])

    assert_equal "America/New_York", model.zone
    from = Time.utc(2026, 8, 11)
    assert_operator model.next_time(from).to_utc_time, :<, brief.next_time(from).to_utc_time
  end

  test "the ingest seam queues a run rather than running one inline, carrying the new poll ids" do
    assert_no_difference "ModelRun.count" do
      assert_enqueued_with(job: Forecast::RunJob, args: [ { trigger: :ingest, poll_ids: [ 7, 9 ] } ]) do
        Ingest.after_new_polls!([ 7, 9 ])
      end
    end
  end

  test "a sweep that created nothing queues nothing" do
    assert_no_enqueued_jobs do
      Ingest.after_new_polls!([])
    end
  end

  # The handoff the newsroom depends on: the polls that triggered the run reach
  # the reaction job, and only after the run they caused has actually succeeded.
  test "a successful run hands its poll ids to the newsroom" do
    poll_ids = [ polls(:maine_poll_one).id, polls(:maine_poll_two).id ]

    assert_enqueued_with(job: Newsroom::PollReactionsJob) do
      assert_enqueued_with(job: Newsroom::MovementNotesJob) do
        Forecast::RunJob.perform_now(trigger: :ingest, poll_ids: poll_ids)
      end
    end

    run = ModelRun.succeeded.latest.first
    reactions = enqueued_jobs.find { |job| job[:job] == Newsroom::PollReactionsJob }
    assert_equal({ "model_run_id" => run.id, "poll_ids" => poll_ids },
                 reactions[:args].sole.except("_aj_ruby2_keywords", "_aj_symbol_keys"))
  end

  test "a cron run has no new polls to react to, but is still checked for movement" do
    Forecast::RunJob.perform_now(trigger: :cron)

    assert_enqueued_jobs 1, only: Newsroom::MovementNotesJob
    assert_enqueued_jobs 0, only: Newsroom::PollReactionsJob
  end

  test "a run that failed is not something to write about" do
    raising(ChamberForecast, :insert_all!, "the database is on fire") do
      assert_raises(StandardError) { Forecast::RunJob.perform_now(trigger: :ingest, poll_ids: [ 1 ]) }
    end

    assert_enqueued_jobs 0, only: [ Newsroom::PollReactionsJob, Newsroom::MovementNotesJob ]
  end

  test "a run that stepped aside writes nothing" do
    ModelRun.create!(status: :running, trigger: :cron, started_at: 1.minute.ago)

    Forecast::RunJob.perform_now(trigger: :ingest, poll_ids: [ 1 ])

    assert_enqueued_jobs 0, only: [ Newsroom::PollReactionsJob, Newsroom::MovementNotesJob ]
  end

  test "a scrape that found new polls ends with a forecast queued" do
    stub_wikipedia_page("2026 United States Senate election in Maine", body: poll_page_html(rows: [
      { pollster: "Harbor Analytics", dates: "July 8–10, 2026", sample: "600 (LV)", dem: "48%", rep: "44%" }
    ]))
    stub_wikipedia_page("2026 United States Senate special election in Florida", status: 404)
    stub_wikipedia_page("2026 United States elections", body: poll_page_html(rows: [], dem_column: "Democratic", rep_column: "Republican"))
    stub_district_pages

    assert_enqueued_jobs 1, only: Forecast::RunJob do
      Ingest::ScrapeAllJob.perform_now
    end
  end
end
