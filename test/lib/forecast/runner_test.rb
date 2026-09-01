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
    assert_equal Race.where(office: %i[senate house]).count, run.forecasts.excl_internals.count
    assert_equal Race.where(office: %i[senate house]).count, run.forecasts.incl_internals.count
    assert_equal Race.where(office: %i[senate house]).order(:id).pluck(:id), run.forecasts.excl_internals.order(:race_id).pluck(:race_id)
    assert_equal %w[senate house], run.chamber_forecasts.excl_internals.order(:chamber).map(&:chamber)
    assert_equal %w[senate house], run.chamber_forecasts.incl_internals.order(:chamber).map(&:chamber)
  end

  test "the run records everything needed to reproduce it" do
    run = Forecast::Runner.call(trigger: :cron, as_of: AS_OF, seed: SEED)

    assert_equal SEED, run.rng_seed
    assert_equal Pol::Params.to_h.deep_stringify_keys, run.params_snapshot.except("internals_estimate")
    assert_equal 100_000, run.params_snapshot.dig("simulation", "n_sims")
    # The fixture world holds no partisan polls, so the recorded shift is the
    # prior, from zero pairs.
    assert_equal({ "shift" => 3.0, "prior" => 3.0, "empirical_mean" => nil, "pair_count" => 0 },
                 run.params_snapshot.fetch("internals_estimate"))
  end

  test "an n_sims override is recorded in the snapshot, not the configured value" do
    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 50)

    assert_equal 50, run.params_snapshot.dig("simulation", "n_sims"),
                 "the snapshot must describe the run that happened, not the configured one"
    assert_equal 50, run.n_sims
    assert_equal 100_000, Pol::Params.fetch!(:simulation, :n_sims),
                 "the override must not leak into the memoized params"
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

    assert_equal first.forecasts.order(:variant, :race_id).pluck(*columns),
                 second.forecasts.order(:variant, :race_id).pluck(*columns)
    assert_equal first.chamber_forecasts.order(:variant, :chamber).pluck(:p_dem_control, :mean_dem_seats, :seat_histogram),
                 second.chamber_forecasts.order(:variant, :chamber).pluck(:p_dem_control, :mean_dem_seats, :seat_histogram)
  end

  # --- The full-scenario golden -------------------------------------------
  # The fixture world at a fixed date and seed. These numbers are checked
  # against hand arithmetic in the assertions that follow, and are here to
  # catch a formula drifting silently in a later phase. Re-pinned in Phase 10,
  # which replaced one correlated error term with four: the mu arithmetic is
  # untouched (every hand-computed central estimate below still holds), and
  # what moved is the width around it. The fixture world's three races are in
  # Maine, Florida and New York — three states in three census divisions — so
  # they share the national term and nothing else; the state term is exercised
  # end to end by the test after this one.

  test "the fixture world produces exactly these forecasts" do
    runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED)
    run = runner.call

    # One generic-ballot poll in the window (46.5 D − 44.5 R), so the national
    # environment is exactly that poll's margin.
    assert_in_delta 2.0, runner.national_env, 1e-9
    assert_equal 1, runner.generic_ballot.poll_count

    maine = run.forecasts.excl_internals.find_by(race_id: races(:senate_maine).id)
    florida = run.forecasts.excl_internals.find_by(race_id: races(:senate_florida_special).id)
    ny17 = run.forecasts.excl_internals.find_by(race_id: races(:house_ny_17).id)

    # Maine: prior 3.5 + 2.0 − 1.5 = 4.0. Polls: +3.5 at 18 days on n=812
    # (weight 0.4771598) and +1.0 at 8 days on n=650 (weight 0.7004287),
    # W = 1.1775884, average +2.0130020, w = W/3 = 0.3925295,
    # mu = 0.3925295 × 2.0130020 + 0.6074705 × 4.0 = 3.2200447.
    # A polled Senate race's total error is unchanged by Phase 10 — sqrt(3² +
    # 2² + 2² + 2.2913²) × t = 4.7170 × 1.5222 = 7.1804 — so the 100,000 draws
    # around that mu have a standard error of 0.023, and the simulated mean
    # lands 0.032 from it, about 1.4 of those.
    #
    # The exact-value pins below moved when simulation.n_sims went 10,000 →
    # 100,000 on 2026-08-31: ten times as many draws is a wholly different walk
    # through the same seeded stream, not a longer prefix of the old one, so
    # every Monte Carlo output is redrawn. p_dem_win went 0.6743 → 0.67456,
    # inside the ~0.005 standard error the old count carried. The analytic
    # anchors either side of them — the poll weight, mu, and the sigma
    # recovered from the percentile spread — are unchanged, which is what says
    # the model did not move and only its resolution did.
    assert_in_delta 1.1775884, maine.effective_poll_weight, 1e-7
    assert_in_delta 3.2200447, maine.mean_margin, 0.15
    assert_equal 0.67456, maine.p_dem_win
    assert_in_delta 0.32544, maine.p_rep_win, 1e-9
    assert_equal 0.0, maine.p_other_win
    assert_in_delta 3.2522153, maine.mean_margin, 1e-6
    assert_in_delta(-8.5893115, maine.margin_percentiles["5"], 1e-6)
    assert_in_delta 3.2666087, maine.margin_percentiles["50"], 1e-6
    assert_in_delta 15.0532007, maine.margin_percentiles["95"], 1e-6
    # p95 − p5 over 2 × 1.6448536 recovers the sigma above from the output.
    assert_in_delta 4.7170 * 1.5222222,
                    (maine.margin_percentiles["95"] - maine.margin_percentiles["5"]) / (2 * 1.6448536), 0.15

    # Florida's special has no polls: mu is the prior, −12.0 + 2.0 − 1.5, and
    # the wider unpolled sigma.
    assert_equal 0.0, florida.effective_poll_weight
    assert_in_delta(-11.5, florida.mean_margin, 0.3)
    assert_in_delta(-11.4998129, florida.mean_margin, 1e-6)
    assert_equal 0.18383, florida.p_dem_win

    # NY-17: 2.7 + (2.0 − −2.6) = 7.3, no district polls.
    assert_in_delta 7.3, ny17.mean_margin, 0.3
    assert_in_delta 7.2854653, ny17.mean_margin, 1e-6
    assert_equal 0.74352, ny17.p_dem_win
    # The one total Phase 10 deliberately moved: a district's error is now
    # sqrt(17 + 6²) = 7.2801 where it was 6.5000, so NY-17's 5th-to-95th
    # spread widens with it.
    assert_in_delta Math.sqrt(53) * 1.5222222,
                    (ny17.margin_percentiles["95"] - ny17.margin_percentiles["5"]) / (2 * 1.6448536), 0.2

    senate = run.chamber_forecasts.excl_internals.find_by(chamber: :senate)
    # 34 holdovers plus the two seats up: 34 + 0.67456 + 0.18383. Nobody can
    # reach 51, or 50, from there.
    assert_in_delta 34.85839, senate.mean_dem_seats, 1e-9
    assert_equal 0.0, senate.p_dem_control
    assert_equal 0.0, senate.p_rep_control
    # The bins are counts of simulated worlds, so they sum to n_sims, not to
    # the 10,000 they summed to before the count was raised.
    assert_equal({ "34" => 28_668, "35" => 56_825, "36" => 14_507 }, senate.seat_histogram)
    assert_equal 100_000, senate.seat_histogram.values.sum

    house = run.chamber_forecasts.excl_internals.find_by(chamber: :house)
    assert_in_delta 0.74352, house.mean_dem_seats, 1e-9
    assert_equal 0.0, house.p_dem_control
    assert_equal({ "0" => 25_648, "1" => 74_352 }, house.seat_histogram)
    assert_equal 100_000, house.seat_histogram.values.sum
  end

  # End to end, through the real Race rows: the state a race sits in is a
  # model input now, and Forecast::RaceModel#to_entry is what carries it. Two
  # House districts in Maine, alongside Maine's Senate race, all with the
  # state's shared error — and one district in Oregon, which has only the
  # national term in common with them. The Maine trio's margins move together
  # far more than the Oregon one moves with any of them, which can only be
  # true if the state reached the simulator.
  test "a state's races are correlated through the state the runner hands over" do
    maine = Race.create!(office: :house, state: "ME", district: 1, cycle: 2026,
                         slug: "house-me-01-state-term-test", baseline_margin: 0.0)
    also_maine = Race.create!(office: :house, state: "ME", district: 3, cycle: 2026,
                              slug: "house-me-03-state-term-test", baseline_margin: 0.0)
    oregon = Race.create!(office: :house, state: "OR", district: 4, cycle: 2026,
                          slug: "house-or-04-state-term-test", baseline_margin: 0.0)

    # Every district sits at mu = baseline + swing = 0 + 4.6, so any
    # difference between their win probabilities is error, not fundamentals.
    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED)
    probability = ->(race) { run.forecasts.excl_internals.find_by(race_id: race.id).p_dem_win }

    assert_in_delta probability.call(maine), probability.call(also_maine), 0.02
    assert_operator (probability.call(maine) - probability.call(also_maine)).abs, :<,
                    (probability.call(maine) - probability.call(oregon)).abs
  end

  test "percentile keys are strings in the order the site reads them" do
    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 100)

    assert_equal %w[5 25 50 75 95], run.forecasts.first.margin_percentiles.keys
  end

  # --- Inputs -------------------------------------------------------------

  test "with no generic-ballot polls the national environment falls back to 2024" do
    Poll.for_generic_ballot.destroy_all
    runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 2000)
    runner.call

    assert_in_delta(-2.6, runner.national_env, 1e-9)
    # ... which leaves every district exactly at its 2024 baseline. A district's
    # error is sqrt(53) × 1.5222 = 11.08, so 2,000 draws put a standard error of
    # 0.25 on the simulated mean and 0.75 is three of them.
    assert_in_delta races(:house_ny_17).baseline_margin,
                    runner.model_run.forecasts.excl_internals.find_by(race_id: races(:house_ny_17).id).mean_margin, 0.75
  end

  test "governor races are not part of the chamber model and get no forecast" do
    Race.create!(office: :governor, state: "ME", cycle: 2026, slug: "governor-me-2026", lean: 3.5)

    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 100)

    assert_equal 3, run.forecasts.excl_internals.count
    assert_empty run.forecasts.joins(:race).where(races: { office: Race.offices[:governor] })
  end

  test "an uncontested race is certain and still gets a forecast row" do
    races(:senate_maine).update!(uncontested: true, uncontested_party: :dem)

    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 100)
    maine = run.forecasts.excl_internals.find_by(race_id: races(:senate_maine).id)

    assert_equal 1.0, maine.p_dem_win
    assert_equal 0.0, maine.p_rep_win
    assert_equal maine.mean_margin, maine.margin_percentiles["50"]
    # 34 holdovers, Maine's certain seat, and whatever Florida's special does.
    assert_operator run.chamber_forecasts.excl_internals.find_by(chamber: :senate).mean_dem_seats, :>=, 35.0
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

  # --- Dual variants (the internals toggle's engine) ------------------------

  test "with no flagged polls the two variants are exactly equal" do
    run = Forecast::Runner.call(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 200)
    columns = %i[race_id p_dem_win p_rep_win p_other_win mean_margin margin_percentiles effective_poll_weight]

    assert_equal run.forecasts.excl_internals.order(:race_id).pluck(*columns),
                 run.forecasts.incl_internals.order(:race_id).pluck(*columns)
    assert_equal run.chamber_forecasts.excl_internals.order(:chamber).pluck(:p_dem_control, :mean_dem_seats),
                 run.chamber_forecasts.incl_internals.order(:chamber).pluck(:p_dem_control, :mean_dem_seats)
  end

  test "a flagged poll moves only the internals variant, and only its race" do
    # A heavily Democratic internal on Maine. The default variant never sees
    # it; the internals variant reads it shifted and half-weighted.
    create_poll(pollster: pollsters(:delta_metrics), field_end: AS_OF - 1, sample_size: 900,
                race: races(:senate_maine), matchup_key: polls(:maine_poll_one).matchup_key,
                results: { dem: 58.0, rep: 38.0 }, partisan: :dem, entry_mode: :nyt)

    runner = Forecast::Runner.new(trigger: :manual, as_of: AS_OF, seed: SEED, n_sims: 200)
    run = runner.call

    maine_excl = run.forecasts.excl_internals.find_by(race_id: races(:senate_maine).id)
    maine_incl = run.forecasts.incl_internals.find_by(race_id: races(:senate_maine).id)
    ny_excl = run.forecasts.excl_internals.find_by(race_id: races(:house_ny_17).id)
    ny_incl = run.forecasts.incl_internals.find_by(race_id: races(:house_ny_17).id)

    assert_not_equal maine_excl.mean_margin, maine_incl.mean_margin
    assert_operator maine_incl.mean_margin, :>, maine_excl.mean_margin
    # Same seed, same generic ballot, same every-other-input: an unflagged
    # race's numbers are bit-identical across the variants.
    assert_equal ny_excl.mean_margin, ny_incl.mean_margin
    assert_equal ny_excl.p_dem_win, ny_incl.p_dem_win
    # The default variant's poll weight is unchanged by the flagged poll's
    # existence; the internals variant carries the extra half-weight.
    assert_operator maine_incl.effective_poll_weight, :>, maine_excl.effective_poll_weight
  end
end
