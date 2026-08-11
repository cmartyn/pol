require "test_helper"

class Forecast::RunnerTest < ActiveSupport::TestCase
  # Pinned so the fixture polls sit at known ages: the generic-ballot poll is
  # 4 days old, Maine's two are 18 and 8.
  AS_OF = Date.new(2026, 8, 1)
  SEED = 20260801

  test "a run forecasts every race and both chambers, and closes itself" do
    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED)

    assert_predicate run, :succeeded?
    assert_equal "manual", run.trigger
    assert_not_nil run.started_at
    assert_not_nil run.finished_at
    assert_nil run.error_message
    assert_equal Race.where(office: %i[senate house]).count, run.forecasts.count
    assert_equal Race.where(office: %i[senate house]).order(:id).pluck(:id), run.forecasts.order(:race_id).pluck(:race_id)
    assert_equal %w[senate house], run.chamber_forecasts.order(:chamber).map(&:chamber)
  end

  test "the run records everything needed to reproduce it" do
    run = Forecast::Runner.call(trigger: :cron, as_of: AS_OF, seed: SEED)

    assert_equal SEED, run.rng_seed
    assert_equal Pol::Params.to_h.deep_stringify_keys, run.params_snapshot
    assert_equal 10_000, run.params_snapshot.dig("simulation", "n_sims")
  end

  test "a run with no seed given draws one and stores it" do
    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, n_sims: 50)

    assert_not_nil run.rng_seed
    assert_operator run.rng_seed, :>=, 0
    assert_operator run.rng_seed, :<, 2**62
  end

  test "the same seed and date reproduce the run exactly" do
    columns = %i[race_id p_dem_win p_rep_win p_other_win mean_margin margin_percentiles effective_poll_weight]
    first = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED)
    second = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED)

    assert_equal first.forecasts.order(:race_id).pluck(*columns), second.forecasts.order(:race_id).pluck(*columns)
    assert_equal first.chamber_forecasts.order(:chamber).pluck(:p_dem_control, :mean_dem_seats, :seat_histogram),
                 second.chamber_forecasts.order(:chamber).pluck(:p_dem_control, :mean_dem_seats, :seat_histogram)
  end

  # --- The full-scenario golden -------------------------------------------
  # The fixture world at a fixed date and seed. These numbers are checked
  # against hand arithmetic in the assertions that follow, and are here to
  # catch a formula drifting silently in a later phase.

  test "the fixture world produces exactly these forecasts" do
    runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED)
    run = runner.call

    # One generic-ballot poll in the window (46.5 D − 44.5 R), so the national
    # environment is exactly that poll's margin.
    assert_in_delta 2.0, runner.national_env, 1e-9
    assert_equal 1, runner.generic_ballot.poll_count

    maine = run.forecasts.find_by(race_id: races(:senate_maine).id)
    florida = run.forecasts.find_by(race_id: races(:senate_florida_special).id)
    ny17 = run.forecasts.find_by(race_id: races(:house_ny_17).id)

    # Maine: prior 3.5 + 2.0 − 1.5 = 4.0. Polls: +3.5 at 18 days on n=812
    # (weight 0.4771598) and +1.0 at 8 days on n=650 (weight 0.7004287),
    # W = 1.1775884, average +2.0130020, w = W/3 = 0.3925295,
    # mu = 0.3925295 × 2.0130020 + 0.6074705 × 4.0 = 3.2200447.
    # 10,000 draws around that mu have a standard error of 0.07, and the
    # simulated mean lands 0.06 away.
    assert_in_delta 1.1775884, maine.effective_poll_weight, 1e-7
    assert_in_delta 3.2200447, maine.mean_margin, 0.15
    assert_equal 0.6714, maine.p_dem_win
    assert_equal 0.3286, maine.p_rep_win
    assert_equal 0.0, maine.p_other_win
    assert_in_delta 3.2824395, maine.mean_margin, 1e-6
    assert_in_delta(-8.4884637, maine.margin_percentiles["5"], 1e-6)
    assert_in_delta 3.2395528, maine.margin_percentiles["50"], 1e-6
    assert_in_delta 15.1840294, maine.margin_percentiles["95"], 1e-6

    # Florida's special has no polls: mu is the prior, −12.0 + 2.0 − 1.5, and
    # the wider unpolled sigma.
    assert_equal 0.0, florida.effective_poll_weight
    assert_in_delta(-11.5, florida.mean_margin, 0.3)
    assert_in_delta(-11.4875265, florida.mean_margin, 1e-6)
    assert_equal 0.1845, florida.p_dem_win

    # NY-17: 2.7 + (2.0 − −2.6) = 7.3, no district polls.
    assert_in_delta 7.3, ny17.mean_margin, 0.3
    assert_in_delta 7.2004515, ny17.mean_margin, 1e-6
    assert_equal 0.7663, ny17.p_dem_win

    senate = run.chamber_forecasts.find_by(chamber: :senate)
    # 34 holdovers plus the two seats up: 34 + 0.6714 + 0.1845. Nobody can
    # reach 51, or 50, from there.
    assert_in_delta 34.8559, senate.mean_dem_seats, 1e-9
    assert_equal 0.0, senate.p_dem_control
    assert_equal 0.0, senate.p_rep_control
    assert_equal({ "34" => 2808, "35" => 5825, "36" => 1367 }, senate.seat_histogram)

    house = run.chamber_forecasts.find_by(chamber: :house)
    assert_in_delta 0.7663, house.mean_dem_seats, 1e-9
    assert_equal 0.0, house.p_dem_control
    assert_equal({ "0" => 2337, "1" => 7663 }, house.seat_histogram)
  end

  test "percentile keys are strings in the order the site reads them" do
    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 100)

    assert_equal %w[5 25 50 75 95], run.forecasts.first.margin_percentiles.keys
  end

  # --- Inputs -------------------------------------------------------------

  test "with no generic-ballot polls the national environment falls back to 2024" do
    Poll.for_generic_ballot.destroy_all
    runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 100)
    runner.call

    assert_in_delta(-2.6, runner.national_env, 1e-9)
    # ... which leaves every district exactly at its 2024 baseline.
    assert_in_delta races(:house_ny_17).baseline_margin,
                    runner.model_run.forecasts.find_by(race_id: races(:house_ny_17).id).mean_margin, 0.3
  end

  test "governor races are not part of the chamber model and get no forecast" do
    Race.create!(office: :governor, state: "ME", cycle: 2026, slug: "governor-me-2026", lean: 3.5)

    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 100)

    assert_equal 3, run.forecasts.count
    assert_empty run.forecasts.joins(:race).where(races: { office: Race.offices[:governor] })
  end

  test "an uncontested race is certain and still gets a forecast row" do
    races(:senate_maine).update!(uncontested: true, uncontested_party: :dem)

    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 100)
    maine = run.forecasts.find_by(race_id: races(:senate_maine).id)

    assert_equal 1.0, maine.p_dem_win
    assert_equal 0.0, maine.p_rep_win
    assert_equal maine.mean_margin, maine.margin_percentiles["50"]
    # 34 holdovers, Maine's certain seat, and whatever Florida's special does.
    assert_operator run.chamber_forecasts.find_by(chamber: :senate).mean_dem_seats, :>=, 35.0
  end

  # --- Concurrency --------------------------------------------------------

  test "the database refuses a second running run, whoever asks" do
    ModelRun.create!(status: :running, trigger: :ingest, started_at: 1.minute.ago)

    assert_no_difference "ModelRun.count" do
      assert_raises(Forecast::Runner::AlreadyRunning) do
        Forecast::Runner.call(trigger: :manual, as_of: AS_OF, n_sims: 50)
      end
    end
  end

  # The guard is a partial unique index, not a Ruby check, so it holds against
  # two inserts in the same instant rather than only against sequential ones.
  # This is the closest a single-process test can get to that: it proves the
  # constraint is enforced by the database, which is what makes the atomicity
  # true. The literal in the index has to match the enum, so that is pinned too.
  test "only one running run can exist at the database level" do
    assert_equal 0, ModelRun.statuses.fetch("running"),
                 "the partial index is defined WHERE status = 0"

    ModelRun.create!(status: :running, trigger: :ingest, started_at: 1.minute.ago)

    assert_raises(ActiveRecord::RecordNotUnique) do
      ModelRun.create!(status: :running, trigger: :manual, started_at: Time.current)
    end
  end

  test "runs that are not running are not covered by the guard" do
    assert_nothing_raised do
      3.times { ModelRun.create!(status: :succeeded, trigger: :cron, started_at: Time.current) }
      3.times { ModelRun.create!(status: :failed, trigger: :cron, started_at: Time.current) }
    end
  end

  test "an abandoned run is failed and its successor runs" do
    stale_minutes = Pol::Params.fetch!(:simulation, :stale_run_minutes)
    abandoned = ModelRun.create!(status: :running, trigger: :ingest, started_at: (stale_minutes + 1).minutes.ago)

    run = Forecast::Runner.call(trigger: :cron, as_of: AS_OF, seed: SEED, n_sims: 50)

    assert_predicate run, :succeeded?
    assert_predicate abandoned.reload, :failed?
    assert_match(/abandoned: still running after #{stale_minutes} minutes/, abandoned.error_message)
    assert_not_nil abandoned.finished_at
    # The wreck keeps its own record rather than being quietly reused.
    assert_not_equal abandoned.id, run.id
  end

  test "a running row with no started_at at all is treated as abandoned" do
    orphan = ModelRun.create!(status: :running, trigger: :ingest, started_at: nil)

    Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)

    assert_predicate orphan.reload, :failed?
  end

  test "a run inside the staleness window still blocks" do
    stale_minutes = Pol::Params.fetch!(:simulation, :stale_run_minutes)
    fresh = ModelRun.create!(status: :running, trigger: :ingest, started_at: (stale_minutes - 1).minutes.ago)

    assert_raises(Forecast::Runner::AlreadyRunning) do
      Forecast::Runner.call(trigger: :manual, as_of: AS_OF, n_sims: 50)
    end

    assert_predicate fresh.reload, :running?
  end

  # A run that fails leaves no running row behind, so it never becomes the
  # thing that blocks the next one.
  test "a failed run unblocks the next one immediately" do
    raising(ChamberForecast, :insert_all!, "the database fell over") do
      assert_raises(RuntimeError) { Forecast::Runner.call(trigger: :manual, as_of: AS_OF, n_sims: 50) }
    end

    assert_empty ModelRun.running
    assert_predicate Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50), :succeeded?
  end

  # --- Failure ------------------------------------------------------------

  test "a run that blows up marks itself failed and re-raises outside production" do
    assert_raises(NoMethodError) do
      stubbing(Forecast::Simulator, :new, nil) { Forecast::Runner.call(trigger: :manual, as_of: AS_OF) }
    end

    run = ModelRun.latest.first
    assert_predicate run, :failed?
    assert_match(/NoMethodError/, run.error_message)
    assert_not_nil run.finished_at
    assert_equal 0, run.forecasts.count
  end

  # The race forecasts and the chamber rows go in together or not at all: a run
  # that wrote 470 races and no chambers would look succeeded-ish to the site.
  test "a failure part-way through the write leaves nothing behind" do
    raising(ChamberForecast, :insert_all!, "the database fell over") do
      assert_raises(RuntimeError) { Forecast::Runner.call(trigger: :manual, as_of: AS_OF, n_sims: 50) }
    end

    run = ModelRun.latest.first
    assert_predicate run, :failed?
    assert_equal 0, run.forecasts.count
    assert_equal 0, run.chamber_forecasts.count
  end

  test "in production the failure is logged and swallowed so the job does not retry forever" do
    logger = FakeLogger.new

    run = stubbing(Forecast::Simulator, :new, nil) do
      Forecast::Runner.call(trigger: :ingest, as_of: AS_OF, raise_on_error: false, logger: logger)
    end

    assert_predicate run, :failed?
    assert_match(/failed/, logger.errors.join)
  end

  test "the previous succeeded run stays the one the site shows until the new one lands" do
    old = model_runs(:model_run_one)
    assert_equal old.id, ModelRun.succeeded.latest.first.id

    stubbing(Forecast::Simulator, :new, nil) do
      assert_raises(StandardError) { Forecast::Runner.call(trigger: :cron, as_of: AS_OF) }
    end

    assert_equal old.id, ModelRun.succeeded.latest.first.id
  end

  class FakeLogger
    attr_reader :errors

    def initialize
      @errors = []
    end

    def info(message) = nil
    def warn(message) = nil
    def error(message) = @errors << message
  end
end
