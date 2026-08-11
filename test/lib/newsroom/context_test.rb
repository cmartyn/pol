require "test_helper"

class Newsroom::ContextTest < ActiveSupport::TestCase
  # Everything the model is told comes from these rows and nowhere else, so
  # these tests are the ones that decide what it is possible for a dispatch to
  # say. They run entirely off fixtures; no request leaves the process.
  setup do
    @race = races(:senate_maine)
    @run = model_runs(:model_run_one)
    @polls = [ polls(:maine_poll_one), polls(:maine_poll_two) ]
  end

  test "a poll reaction payload carries the race, its candidates and the current forecast" do
    payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)

    assert_equal "poll_reaction", payload[:kind]
    assert_equal "Maine Senate", payload.dig(:race, :name)
    assert_equal "Maine", payload.dig(:race, :state)
    assert_equal({ name: "Pat Rivers", party: "Republican" }, payload.dig(:race, :incumbent))
    assert_includes payload.dig(:race, :candidates), { name: "Jordan Ellis", party: "Democrat", incumbent: false }

    forecast = payload.dig(:race, :forecast)
    assert_equal "62%", forecast[:dem_win]
    assert_equal "38%", forecast[:rep_win]
    assert_equal "62 in 100", forecast[:dem_win_in_100]
    assert_equal "D+3.2", forecast[:mean_margin]
    assert_match(/5th–95th percentile: R\+6.5 to D\+12.8/, forecast[:range_5_95])
  end

  test "each poll arrives with everything needed to attribute a number to it" do
    payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)

    poll = payload[:polls].find { |entry| entry[:id] == polls(:maine_poll_one).id }
    assert_equal "Beacon Polling", poll[:pollster]
    assert_equal "July 10-14, 2026", poll[:fielded]
    assert_equal 812, poll[:sample_size]
    assert_equal "likely voters", poll[:population]
    assert_equal "example.com", poll[:source]
    assert_equal [ { candidate: "Jordan Ellis", party: "Democrat", pct: 47.5 },
                   { candidate: "Pat Rivers", party: "Republican", pct: 44.0 } ], poll[:results]
  end

  test "citable_poll_ids is exactly the polls in the payload — the set the validator holds citations to" do
    payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)

    assert_equal @polls.map(&:id).sort, payload[:citable_poll_ids].sort
    assert_equal payload[:polls].map { |poll| poll[:id] }.sort, payload[:citable_poll_ids].sort
  end

  test "the national picture travels with every piece, and the House number never travels alone" do
    payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)
    national = payload[:national]

    assert_equal "55%", national.dig(:senate, :dem_control)
    assert_equal 51.2, national.dig(:senate, :mean_dem_seats)
    assert_equal "48%", national.dig(:house, :dem_control)
    assert_match(/overstates certainty/, national.dig(:house, :must_say))
    assert_nil national.dig(:senate, :must_say)
    assert_equal "D+2.0", national.dig(:generic_ballot, :average)
    assert_equal 1, national.dig(:generic_ballot, :polls_in_average)
  end

  test "with no generic-ballot polls the payload says so instead of inventing a number" do
    Poll.for_generic_ballot.destroy_all

    payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)

    assert_nil payload.dig(:national, :generic_ballot, :average)
    assert_match(/no generic-ballot polls/, payload.dig(:national, :generic_ballot, :note))
  end

  test "the countdown is computed from the election date in model_params.yml" do
    travel_to Time.zone.parse("2026-10-04 12:00:00") do
      payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)

      assert_equal 30, payload[:days_to_election]
      assert_equal "November 3, 2026", payload[:election_date]
    end
  end

  test "the prior forecast is included so a reaction can say whether anything changed" do
    earlier = ModelRun.create!(status: :succeeded, trigger: :ingest, started_at: 3.days.before(@run.started_at))
    Forecast.create!(model_run: earlier, race: @race, p_dem_win: 0.54, p_rep_win: 0.46, mean_margin: 1.1)

    payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)

    assert_equal "54%", payload.dig(:race, :previous_forecast, :dem_win)
    assert_match(/ET\z/, payload.dig(:race, :previous_forecast, :from_run_at))
  end

  test "a movement note payload states the move in points, with its direction and span" do
    previous = ModelRun.create!(status: :succeeded, trigger: :cron,
                                started_at: 7.days.before(@run.started_at),
                                finished_at: 7.days.before(@run.started_at))
    Forecast.create!(model_run: previous, race: @race, p_dem_win: 0.50, p_rep_win: 0.50, mean_margin: 0.0)

    payload = Newsroom::Context.movement_note(race: @race, model_run: @run, previous_run: previous)

    assert_equal "movement_note", payload[:kind]
    assert_equal "+12.0 points of Democratic win probability", payload.dig(:movement, :change)
    assert_equal "the Democrat", payload.dig(:movement, :toward)
    assert_equal "50%", payload.dig(:movement, :from)
    assert_equal "62%", payload.dig(:movement, :to)
    assert_equal 7, payload.dig(:movement, :days_between)
  end

  test "a movement note may cite only the polls that arrived since the earlier run" do
    # The fixtures' polls were recorded before the comparison run, which is
    # what makes them the wrong thing to cite for movement since it.
    Poll.where(id: @polls.map(&:id)).update_all(created_at: 30.days.ago)
    previous = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.hour.ago, finished_at: 1.hour.ago)
    Forecast.create!(model_run: previous, race: @race, p_dem_win: 0.50, p_rep_win: 0.50, mean_margin: 0.0)
    fresh = create_poll(pollster: pollsters(:beacon_polling), race: @race, field_end: Date.current,
                        sample_size: 700, results: { dem: 49.0, rep: 44.0 })

    payload = Newsroom::Context.movement_note(race: @race, model_run: @run, previous_run: previous)

    assert_equal [ fresh.id ], payload[:citable_poll_ids]
  end

  test "the daily brief describes the board, not one race" do
    older = ModelRun.create!(status: :succeeded, trigger: :cron,
                             started_at: 7.days.before(@run.started_at),
                             finished_at: 7.days.before(@run.started_at))
    Forecast.create!(model_run: older, race: @race, p_dem_win: 0.40, p_rep_win: 0.60, mean_margin: -4.0)

    payload = Newsroom::Context.daily_brief(model_run: @run)

    assert_equal "daily_brief", payload[:kind]
    assert_nil payload[:race]
    assert_equal "48%", payload.dig(:national, :house, :dem_control)
    assert_equal [ { race: "Maine Senate", change: "+22.0 points of Democratic win probability",
                     from: "40%", to: "62%" } ], payload[:movers]
    assert_includes payload[:citable_poll_ids], polls(:generic_ballot_poll).id
    assert_equal "generic congressional ballot",
                 payload[:polls].find { |poll| poll[:id] == polls(:generic_ballot_poll).id }[:race]
  end

  test "the brief sees at most brief_poll_count recent polls" do
    with_params(newsroom: { brief_poll_count: 1 }) do
      payload = Newsroom::Context.daily_brief(model_run: @run)

      assert_equal 1, payload[:polls].size
      assert_equal 1, payload[:citable_poll_ids].size
    end
  end

  test "recent headlines are the ones this piece must not repeat" do
    Dispatch.create!(kind: :poll_reaction, race: races(:senate_florida_special), status: :published,
                     headline: "Florida moves", body_markdown: "Body.", published_at: Time.current)

    race_payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)
    brief_payload = Newsroom::Context.daily_brief(model_run: @run)

    assert_equal [ "New Maine poll shows tightening Senate race" ],
                 race_payload[:recent_headlines].map { |entry| entry[:headline] }
    assert_includes brief_payload[:recent_headlines].map { |entry| entry[:headline] }, "Florida moves"
  end

  test "a retracted dispatch is not something to avoid repeating" do
    dispatches(:maine_poll_reaction).update!(status: :retracted)

    payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)

    assert_nil payload[:recent_headlines]
  end

  test "the payload is JSON the way the model will see it" do
    payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)

    round_tripped = JSON.parse(JSON.generate(payload))
    assert_equal "Maine Senate", round_tripped.dig("race", "name")
  end
end
