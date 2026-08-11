require "test_helper"

class Newsroom::MovementNotesJobTest < ActiveJob::TestCase
  setup do
    @race = races(:senate_maine)
    @run = model_runs(:model_run_one)
    dispatches(:maine_poll_reaction).update!(published_at: 30.days.ago)
  end

  def moved_by(points, days_before: 7)
    started_at = days_before.days.before(@run.started_at)
    previous = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: started_at, finished_at: started_at)
    Forecast.create!(model_run: previous, race: @race, p_dem_win: 0.62 - points, p_rep_win: 0.38 + points,
                     mean_margin: 0.0)
    previous
  end

  def perform
    Newsroom::MovementNotesJob.perform_now(model_run_id: @run.id)
  end

  test "a race that moved gets a note built from the two runs" do
    moved_by(0.20)
    stub_openrouter(dispatch_json(cited_poll_ids: []))

    assert_difference "Dispatch.movement_note.count", 1 do
      with_api_key { perform }
    end

    dispatch = Dispatch.movement_note.recent_first.first
    assert_equal @race, dispatch.race
    assert_equal @run, dispatch.model_run
    assert_empty NewsroomSkip.all
  end

  test "the note is written from the movement payload, not a generic one" do
    moved_by(0.20)
    stub_openrouter(dispatch_json(cited_poll_ids: []))

    with_api_key do
      recording_openrouter do |requests|
        perform

        payload = requests.sole[:body]["messages"].last["content"]
        assert_match(/\+20.0 points of Democratic win probability/, payload)
        assert_match(/"movement_note"/, payload)
      end
    end
  end

  test "a run with nothing to compare against writes nothing and says nothing" do
    assert_no_difference [ "Dispatch.count", "NewsroomSkip.count" ] do
      with_api_key { perform }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
  end

  test "a quiet week is not an event" do
    moved_by(0.01)

    assert_no_difference [ "Dispatch.count", "NewsroomSkip.count" ] do
      with_api_key { perform }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
  end

  test "a race written up this week is not written up again" do
    moved_by(0.20)
    Dispatch.create!(kind: :movement_note, race: @race, status: :published, published_at: 2.days.ago,
                     headline: "Maine drifted", body_markdown: "Body.")

    assert_no_difference "Dispatch.count" do
      with_api_key { perform }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
    skip = NewsroomSkip.sole
    assert_predicate skip, :cap_reached?
    assert_predicate skip, :movement_note?
    assert_match(/cooldown is #{Pol::Params.fetch!(:newsroom, :movement_note_cooldown_days)} days/, skip.detail)
  end

  test "the kill switch stops movement notes too" do
    moved_by(0.20)
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")

    assert_no_difference "Dispatch.count" do
      with_api_key { perform }
    end

    assert_predicate NewsroomSkip.sole, :agents_disabled?
    assert_predicate NewsroomSkip.sole, :movement_note?
    assert_equal @race, NewsroomSkip.sole.race
  end

  # This job runs after every successful model run — a dozen times on a busy
  # day — and almost always finds nothing moved. Checking the kill switch
  # before that is what used to fill the skip log with rows for pieces that
  # were never going to exist.
  test "a disabled newsroom is silent on a week when nothing moved" do
    moved_by(0.01)
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")

    assert_no_difference "NewsroomSkip.count" do
      with_api_key { perform }
    end
  end

  test "a disabled newsroom with no run history at all is silent" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")

    assert_no_difference "NewsroomSkip.count" do
      with_api_key { perform }
    end
  end

  test "with no API key nothing is attempted" do
    moved_by(0.20)

    assert_no_difference "Dispatch.count" do
      without_api_key { perform }
    end

    assert_predicate NewsroomSkip.sole, :no_api_key?
  end

  test "the job is enqueueable on the default queue" do
    assert_enqueued_with(job: Newsroom::MovementNotesJob, queue: "default") do
      Newsroom::MovementNotesJob.perform_later(model_run_id: @run.id)
    end
  end
end
