require "test_helper"

class Newsroom::DailyBriefJobTest < ActiveJob::TestCase
  setup do
    dispatches(:maine_poll_reaction).update!(published_at: 30.days.ago)
  end

  test "the cron schedule writes the brief at 07:00 Eastern" do
    entry = Rails.application.config.good_job.cron.fetch(:pol_daily_brief)

    assert_equal "Newsroom::DailyBriefJob", entry[:class]
    assert_equal "0 7 * * * America/New_York", entry[:cron]
    assert entry[:description].present?
  end

  # The sixth field is fugit's timezone, and getting it wrong is invisible
  # until the clocks change: this asserts the parsed schedule really is 07:00
  # Eastern on both sides of a DST boundary, not 07:00 UTC or 07:00 wherever
  # the server happens to live.
  test "the parsed schedule is Eastern all year, not the server's clock" do
    schedule = Fugit.parse_cron(Rails.application.config.good_job.cron.fetch(:pol_daily_brief)[:cron])

    assert_equal "America/New_York", schedule.zone
    summer = schedule.next_time(Time.utc(2026, 7, 1)).to_utc_time
    winter = schedule.next_time(Time.utc(2026, 12, 1)).to_utc_time
    assert_equal 11, summer.hour, "07:00 EDT is 11:00 UTC"
    assert_equal 12, winter.hour, "07:00 EST is 12:00 UTC"
  end

  test "the brief is written from the latest succeeded run" do
    stub_openrouter(dispatch_json(cited_poll_ids: [ polls(:generic_ballot_poll).id ]))

    assert_difference "Dispatch.daily_brief.count", 1 do
      with_api_key { Newsroom::DailyBriefJob.perform_now }
    end

    dispatch = Dispatch.daily_brief.recent_first.first
    assert_nil dispatch.race
    assert_equal model_runs(:model_run_one), dispatch.model_run
    assert_equal [ polls(:generic_ballot_poll).id ], dispatch.cited_poll_ids
    assert_empty NewsroomSkip.all
  end

  test "the brief describes the board" do
    stub_openrouter(dispatch_json(cited_poll_ids: []))

    with_api_key do
      recording_openrouter do |requests|
        Newsroom::DailyBriefJob.perform_now

        messages = requests.sole[:body]["messages"]
        assert_match(/morning national brief/, messages.first["content"])
        assert_match(/"daily_brief"/, messages.last["content"])
        assert_match(/"house"/, messages.last["content"])
      end
    end
  end

  test "with no succeeded run there is no board to describe" do
    Dispatch.update_all(model_run_id: nil)
    ModelRun.update_all(status: ModelRun.statuses.fetch("failed"))

    assert_no_difference [ "Dispatch.count", "NewsroomSkip.count" ] do
      with_api_key { Newsroom::DailyBriefJob.perform_now }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
  end

  test "the brief is subject to the same daily cap as everything else" do
    with_params(newsroom: { max_dispatches_per_day: 1 }) do
      Dispatch.create!(kind: :poll_reaction, race: races(:senate_maine), status: :published,
                       published_at: Time.current, headline: "Something", body_markdown: "Body.")

      assert_no_difference "Dispatch.count" do
        with_api_key { Newsroom::DailyBriefJob.perform_now }
      end
    end

    skip = NewsroomSkip.sole
    assert_predicate skip, :cap_reached?
    assert_predicate skip, :daily_brief?
  end

  test "the kill switch stops the brief" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")

    assert_no_difference "Dispatch.count" do
      with_api_key { Newsroom::DailyBriefJob.perform_now }
    end

    assert_predicate NewsroomSkip.sole, :agents_disabled?
    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
  end

  test "bin/rails pol:brief runs the same job the cron does" do
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("pol:brief")
    stub_openrouter(dispatch_json(cited_poll_ids: []))

    assert_difference "Dispatch.daily_brief.count", 1 do
      with_api_key { capture_io { Rake::Task["pol:brief"].tap(&:reenable).invoke } }
    end
  end

  test "the job is enqueueable on the default queue" do
    assert_enqueued_with(job: Newsroom::DailyBriefJob, queue: "default") do
      Newsroom::DailyBriefJob.perform_later
    end
  end
end
