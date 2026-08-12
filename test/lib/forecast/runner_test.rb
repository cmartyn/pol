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

  # --- House effects (Phase 9) ---------------------------------------------

  # A world where one house is reliably 4 points more Democratic than three
  # others, polled on ten separate days. Beacon's raw effect is +4.0 and its
  # shrunk one is 4.0 × 10/15 = 2.6666667.
  def leaning_world(margin: 8.0, days: 10)
    field = [ pollsters(:cardinal_research), pollsters(:delta_metrics), create_pollster("Katahdin Polling") ]
    Poll.for_generic_ballot.destroy_all

    days.times do |index|
      date = AS_OF - 3 - index
      field.each do |pollster|
        create_poll(pollster: pollster, field_end: date, sample_size: 600, results: { dem: 48.0, rep: 44.0 })
      end
      create_poll(pollster: pollsters(:beacon_polling), field_end: date, sample_size: 600,
                  results: { dem: 44.0 + margin, rep: 44.0 })
    end
  end

  test "a run persists every estimated effect, applied or not" do
    leaning_world

    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)
    beacon = run.house_effects.find_by(pollster_id: pollsters(:beacon_polling).id)

    assert_equal 4, run.house_effects.count, "all four houses in the world got an estimate"
    assert_in_delta 4.0, beacon.effect_raw, 1e-9
    assert_in_delta 4.0 * 10 / 15, beacon.effect_shrunk, 1e-9
    assert_equal 10, beacon.residual_count
    assert_predicate beacon, :applied?
  end

  test "the effects a run applied are the ones its averages used" do
    leaning_world
    runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)
    runner.call

    lookup = HouseEffect.applied_lookup(runner.model_run)
    adjusted = Forecast::Averager.new(as_of: AS_OF, house_effects: lookup).for_generic_ballot.mean_margin

    assert_in_delta lookup.fetch(pollsters(:beacon_polling).id), 4.0 * 10 / 15, 1e-9
    assert_in_delta adjusted, runner.national_env, 1e-12,
                    "the environment is the average taken with this run's own effects"
  end

  # Worth stating as its own property, because it is easy to expect the
  # opposite. Residuals are measured against the other houses, so in a field
  # where everyone polls equally often the effects net out and removing them
  # redistributes weight between pollsters WITHOUT moving the average. A house
  # effect correction that shifted a balanced average would be measuring
  # something other than the gap between houses.
  test "in a field where every house polls equally, removing the effects does not move the average" do
    leaning_world

    unadjusted = Forecast::Averager.new(as_of: AS_OF).for_generic_ballot.mean_margin
    runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)
    runner.call

    assert_in_delta 5.0, unadjusted, 1e-9, "(8 + 4 + 4 + 4) / 4"
    assert_in_delta unadjusted, runner.national_env, 1e-9
    assert_operator HouseEffect.applied_lookup(runner.model_run).values.map(&:abs).max, :>, 0.5,
                    "and it is not because the effects were all zero"
  end

  # Where the correction bites is a race one house has to itself. Beacon's
  # generic-ballot lean is +4.0 raw, +2.6666667 shrunk; Maine's average is its
  # single Beacon poll, so the whole effect comes off it: 5.0 − 2.6666667.
  test "a race polled only by a leaning house moves by that house's whole effect" do
    leaning_world
    races(:senate_maine).polls.destroy_all
    create_poll(pollster: pollsters(:beacon_polling), race: races(:senate_maine), field_end: AS_OF - 3,
                sample_size: 600, results: { dem: 50.0, rep: 45.0 })

    runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)
    runner.call
    maine = runner.race_models.find { |model| model.race.id == races(:senate_maine).id }

    assert_in_delta 5.0 - (4.0 * 10 / 15), maine.average.mean_margin, 1e-9
    assert_in_delta 2.3333333, maine.average.mean_margin, 1e-7
  end

  # The run's rows are its own inputs: reproducing a forecast must not depend
  # on the estimator agreeing with itself a week later.
  test "two runs each get their own effect rows" do
    leaning_world

    first = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)
    second = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)

    assert_equal first.house_effects.count, second.house_effects.count
    assert_empty first.house_effects.pluck(:id) & second.house_effects.pluck(:id)
    assert_equal first.house_effects.order(:pollster_id).pluck(:effect_shrunk),
                 second.house_effects.order(:pollster_id).pluck(:effect_shrunk)
  end

  test "a run cannot record two effects for one pollster" do
    run = model_runs(:model_run_one)
    HouseEffect.create!(model_run: run, pollster: pollsters(:beacon_polling),
                        effect_raw: 1.0, effect_shrunk: 0.5, residual_count: 4, applied: true)

    assert_raises(ActiveRecord::RecordNotUnique) do
      HouseEffect.insert_all!([ {
        model_run_id: run.id, pollster_id: pollsters(:beacon_polling).id,
        effect_raw: 2.0, effect_shrunk: 1.0, residual_count: 9, applied: true,
        created_at: Time.current, updated_at: Time.current
      } ])
    end
  end

  test "a failed run leaves no effect rows behind" do
    leaning_world

    raising(ChamberForecast, :insert_all!, "the database fell over") do
      assert_raises(RuntimeError) { Forecast::Runner.call(trigger: :manual, as_of: AS_OF, n_sims: 50) }
    end

    assert_equal 0, ModelRun.latest.first.house_effects.count
  end

  # The switch has to be a real switch: off means the model's numbers are
  # exactly what they were before this phase existed, while the estimates are
  # still made and still published.
  test "with house effects disabled nothing is applied and the averages are the unadjusted ones" do
    leaning_world

    off = with_params(house_effects: { enabled: false }) do
      runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)
      runner.call
      assert_in_delta Forecast::Averager.new(as_of: AS_OF).for_generic_ballot.mean_margin,
                      runner.national_env, 1e-12
      runner.model_run
    end

    assert_equal 0, off.house_effects.where(applied: true).count
    assert_operator off.house_effects.count, :>, 0, "the estimates are still recorded and still shown"
    assert_empty HouseEffect.applied_lookup(off)
  end

  # The fixture world is too thin for any effect to clear the minimum, which
  # is why every Phase 3 golden above still reads exactly as it did. This
  # pins that, so a change to the estimator that started adjusting the fixture
  # world would fail here — naming the cause — rather than as a wall of
  # moved goldens.
  test "the fixture world produces no applied effects, which is why the Phase 3 goldens hold" do
    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)

    assert_equal 0, run.house_effects.where(applied: true).count
    assert_empty HouseEffect.applied_lookup(run)
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
