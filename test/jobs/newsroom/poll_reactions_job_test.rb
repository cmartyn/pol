require "test_helper"

class Newsroom::PollReactionsJobTest < ActiveJob::TestCase
  setup do
    @race = races(:senate_maine)
    @other_race = races(:senate_florida_special)
    @run = model_runs(:model_run_one)
    @polls = [ polls(:maine_poll_one), polls(:maine_poll_two) ]
    dispatches(:maine_poll_reaction).update!(published_at: 30.days.ago, cited_poll_ids: [])
  end

  def perform(poll_ids: @polls.map(&:id))
    Newsroom::PollReactionsJob.perform_now(model_run_id: @run.id, poll_ids: poll_ids)
  end

  def good_draft(ids = @polls.map(&:id))
    dispatch_json(cited_poll_ids: ids)
  end

  test "one reaction per race that got polls, citing that race's polls" do
    florida_poll = create_poll(pollster: pollsters(:beacon_polling), race: @other_race,
                               field_end: Date.current, sample_size: 700, results: { dem: 45.0, rep: 47.0 })
    stub_request(:post, NewsroomStubHelper::COMPLETIONS_URL).to_return do |request|
      ids = JSON.parse(request.body)["messages"].last["content"][/"citable_poll_ids": \[([^\]]*)\]/m, 1]
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(completion_response(content: dispatch_json(cited_poll_ids: ids.scan(/\d+/).map(&:to_i)))) }
    end

    assert_difference "Dispatch.poll_reaction.count", 2 do
      with_api_key { perform(poll_ids: @polls.map(&:id) + [ florida_poll.id ]) }
    end

    published = Dispatch.published.poll_reaction.where(published_at: 1.minute.ago..)
    assert_equal [ @other_race, @race ].sort_by(&:id), published.map(&:race).sort_by(&:id)
    assert_equal [ florida_poll.id ], published.find_by(race: @other_race).cited_poll_ids
    assert_equal @polls.map(&:id).sort, published.find_by(race: @race).cited_poll_ids.sort
    assert_empty NewsroomSkip.all
  end

  test "generic-ballot polls belong to the brief, not to a race reaction" do
    assert_no_difference "Dispatch.count" do
      with_api_key { perform(poll_ids: [ polls(:generic_ballot_poll).id ]) }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
  end

  # One row per piece that would have been written — here, one race with two
  # new polls — and the race on it, so the admin list says what was suppressed
  # rather than only that something was.
  test "the kill switch stops the newsroom before it says a word" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")

    assert_no_difference "Dispatch.count" do
      with_api_key { perform }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
    skip = NewsroomSkip.sole
    assert_predicate skip, :agents_disabled?
    assert_predicate skip, :poll_reaction?
    assert_equal @race, skip.race
  end

  test "two races that would have been written give two rows, not one for the run" do
    florida_poll = create_poll(pollster: pollsters(:beacon_polling), race: @other_race,
                               field_end: Date.current, sample_size: 700, results: { dem: 45.0, rep: 47.0 })
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")

    with_api_key { perform(poll_ids: @polls.map(&:id) + [ florida_poll.id ]) }

    assert_equal [ @other_race, @race ].sort_by(&:id), NewsroomSkip.all.map(&:race).sort_by(&:id)
    assert NewsroomSkip.all.all?(&:agents_disabled?)
  end

  # The flood this replaced: with the check at the top of the job, every run on
  # the schedule wrote a row whether or not it had anything to say, so a day
  # spent switched off buried the real skips under a dozen no-ops.
  test "a disabled newsroom with nothing to write says nothing at all" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")

    assert_no_difference "NewsroomSkip.count" do
      with_api_key { perform(poll_ids: []) }
      with_api_key { perform(poll_ids: [ polls(:generic_ballot_poll).id ]) }
      with_api_key { Newsroom::PollReactionsJob.perform_now(model_run_id: 0, poll_ids: @polls.map(&:id)) }
    end
  end

  test "the environment kill switch overrides the stored setting" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")

    with_env("AGENTS_DISABLED" => "1") do
      assert_no_difference "Dispatch.count" do
        with_api_key { perform }
      end
    end

    assert_predicate NewsroomSkip.sole, :agents_disabled?
  end

  test "with no API key the newsroom records why it went quiet" do
    assert_no_difference "Dispatch.count" do
      without_api_key { perform }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
    assert_predicate NewsroomSkip.sole, :no_api_key?
    assert_equal @race, NewsroomSkip.sole.race
  end

  test "a missing key with nothing to write is also silent" do
    assert_no_difference "NewsroomSkip.count" do
      without_api_key { perform(poll_ids: []) }
    end
  end

  test "a race at its daily cap gets a logged skip instead of a fourth piece" do
    Pol::Params.fetch!(:newsroom, :max_dispatches_per_race_per_day).times do
      Dispatch.create!(kind: :poll_reaction, race: @race, status: :published, published_at: Time.current,
                       headline: "Already said", body_markdown: "Body.")
    end

    assert_no_difference "Dispatch.count" do
      with_api_key { perform }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
    skip = NewsroomSkip.sole
    assert_predicate skip, :cap_reached?
    assert_equal @race, skip.race
  end

  test "the whole board stops at the global daily cap" do
    with_params(newsroom: { max_dispatches_per_day: 1 }) do
      Dispatch.create!(kind: :daily_brief, status: :published, published_at: Time.current,
                       headline: "The morning brief", body_markdown: "Body.")

      assert_no_difference "Dispatch.count" do
        with_api_key { perform }
      end
    end

    assert_match(/daily cap is 1/, NewsroomSkip.sole.detail)
  end

  test "a poll that has already been written about is not written about again" do
    Dispatch.create!(kind: :poll_reaction, race: @race, status: :published, published_at: 2.hours.ago,
                     headline: "Already covered", body_markdown: "Body.",
                     cited_poll_ids: [ polls(:maine_poll_two).id ])

    assert_no_difference "Dispatch.count" do
      with_api_key { perform }
    end

    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
    assert_predicate NewsroomSkip.sole, :duplicate?
  end

  test "a vanished model run is not a crash" do
    assert_nothing_raised do
      with_api_key { Newsroom::PollReactionsJob.perform_now(model_run_id: 0, poll_ids: @polls.map(&:id)) }
    end
    assert_empty Dispatch.where(published_at: 1.minute.ago..)
  end

  test "the job is enqueueable on the default queue" do
    assert_enqueued_with(job: Newsroom::PollReactionsJob, queue: "default") do
      Newsroom::PollReactionsJob.perform_later(model_run_id: @run.id, poll_ids: [ 1 ])
    end
  end

  private
    def with_env(values)
      previous = ENV.to_hash.slice(*values.keys)
      ENV.update(values)
      yield
    ensure
      values.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
    end
end
