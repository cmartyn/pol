require "test_helper"

class PostElectionTest < ActionDispatch::IntegrationTest
  setup do
    @previous_mode = Rails.configuration.x.post_election
    Rails.configuration.x.post_election = true
    travel_to Time.zone.local(2026, 11, 5, 15)
    @race = races(:senate_maine)
    @race.update!(slug: ForecastArchive.races.keys.find { |slug| ForecastArchive.races[slug]["race_key"] == "ME-S" })
    @run = ModelRun.create!(id: ForecastArchive.run_id, started_at: ForecastArchive.started_at,
      finished_at: ForecastArchive.finished_at, status: :succeeded, trigger: :cron)
    sample = forecasts(:maine_forecast)
    sample.dup.update!(model_run: @run)
    sample.dup.update!(model_run: @run, variant: :incl_internals, p_dem_win: 0.65, p_rep_win: 0.35)
    later = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.hour.ago, finished_at: 58.minutes.ago)
    sample.dup.update!(model_run: later, p_dem_win: 0.99, p_rep_win: 0.01)
    @result = RaceResult.for_race!(@race)
    @winner = { "name" => "Counted Candidate", "party" => "rep" }
    @source = "https://civicapi.org/results/elections/123"
    @report = { reported_at: 2.hours.ago, returns_url: @source,
      votes: [ @winner.merge("party_label" => "Republican", "votes" => 1200) ],
      provider_call: { "status" => "uncalled", "source" => "civicAPI", "url" => @source } }
    @result.import!(@report, fetched_at: 1.hour.ago)
  end

  teardown do
    Rails.configuration.x.post_election = @previous_mode
    travel_back
  end

  test "a result can change on cached race and chamber pages while both variants and history stay pinned" do
    assert_equal @run, ModelRun.published.sole
    assert_equal @run, ModelRun.published_history.latest.first
    assert_equal [ 0.62, 0.65 ], Forecast.latest_for_races(variant: Forecast.variants.keys).order(:variant).pluck(:p_dem_win)
    with_fragment_caching do
      get race_path(@race.slug)
      assert_response :success
      assert_select "[data-testid=race-result]", text: /Uncalled/
      assert_select "[data-testid=win-probability]", text: /62/
      assert_select "[data-testid=win-probability]", text: /65/
      assert_includes response.body, @race.forecast_candidates.first.name
      get senate_path(status: "outstanding")
      assert_select "[data-testid=senate-race-row]", count: 1

      travel 1.second
      call = @report[:provider_call].merge("status" => "projected", "winner" => @winner)
      @result.import!(@report.merge(provider_call: call), fetched_at: Time.current)
      get race_path(@race.slug)
      assert_select "[data-testid=race-result]", text: /Projected winner.*Counted Candidate/m
      assert_select "[data-testid=win-probability]", text: /62/
      get senate_path(status: "outstanding")
      assert_select "[data-testid=senate-race-row]", count: 0
      get senate_path
      assert_select "[data-testid=senate-race-row]", text: /Counted Candidate/
    end
  end

  test "an authenticated editor can certify, correct and release a call while retaining its history" do
    route = admin_race_result_path(@race)
    attrs = { status: "certified", candidate: @winner.to_json, source_url: "https://example.gov/canvass", decided_at: "2026-11-05T13:00" }
    patch route, params: { result: attrs }
    assert_redirected_to new_session_path
    sign_in_as users(:one)
    patch route, params: { result: attrs.merge(candidate: "unlisted candidate") }
    assert_response :unprocessable_entity
    assert_equal "uncalled", @result.reload.status
    patch route, params: { result: attrs }
    assert_redirected_to edit_admin_race_path(@race)
    assert_equal "certified", @result.reload.status
    refute @result.due?(now: 2.days.from_now)
    @result.import!(@report.merge(votes: []), fetched_at: Time.current)
    assert_equal 1200, @result.reload.votes.first["votes"]
    patch route, params: { result: attrs.merge(status: "uncalled") }
    assert_nil @result.reload.winner
    assert @result.due?
    call = @report[:provider_call].merge("status" => "projected", "winner" => @winner)
    @result.import!(@report.merge(provider_call: call), fetched_at: Time.current)
    assert_equal "uncalled", @result.reload.status
    patch route, params: { result: { status: "automatic" } }
    assert_equal "projected", @result.reload.status
    refute @result.due?
    assert @result.due?(now: 1.day.from_now)
    assert_equal %w[uncalled certified uncalled projected], @result.call_history.map { |entry| entry.dig("decision", "status") }
    @result.import!(@report.merge(reported_at: 1.day.ago), fetched_at: 1.minute.from_now)
    assert_equal "projected", @result.reload.status
  end

  test "pre-election jobs queued before the cutover cannot generate another forecast or brief" do
    assert_no_difference [ "ModelRun.count", "Dispatch.count", "ScrapeRun.count" ] do
      Forecast::RunJob.perform_now(trigger: :cron)
      Newsroom::DailyBriefJob.perform_now
      Ingest::NytSyncJob.perform_now
      ElectionNight::SweepJob.perform_now
    end
    refute Setting.agents_enabled?
    refute DispatchEmail.enabled?
  end
end
