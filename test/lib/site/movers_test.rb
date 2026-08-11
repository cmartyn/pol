require "test_helper"

class Site::MoversTest < ActiveSupport::TestCase
  # Real config/model_params.yml values, used directly rather than stubbed —
  # consistent with how the forecast engine's own tests pin against the real
  # numbers (test/lib/forecast/averager_test.rb et al.), so a change to
  # site.* is felt here rather than silently drifting.
  WINDOW_DAYS = Pol::Params.fetch!(:site, :movers_window_days)
  FLOOR_PP = Pol::Params.fetch!(:site, :movers_floor_pp)
  COUNT = Pol::Params.fetch!(:site, :movers_count)

  test "omits the section (returns nil) when only one succeeded run exists" do
    # The out-of-the-box fixture world: model_run_one is the only succeeded
    # run anywhere.
    assert_nil Site::Movers.call
  end

  test "omits the section when the only other succeeded run has no races in common" do
    latest = create_run(started_at: "2026-08-08 12:00:00")
    previous = create_run(started_at: latest.started_at - WINDOW_DAYS.days)
    forecast_for(races(:senate_maine), latest, p_dem_win: 0.60)
    # previous has no forecast for any race at all.

    assert_nil Site::Movers.call
  end

  test "compares the latest run against the succeeded run closest to the window, not the nearest or the oldest" do
    latest = create_run(started_at: "2026-08-08 12:00:00")
    on_target = create_run(started_at: latest.started_at - WINDOW_DAYS.days) # exactly 7 days before
    closer_decoy = create_run(started_at: latest.started_at - 3.days)
    farther_decoy = create_run(started_at: latest.started_at - 20.days)

    forecast_for(races(:senate_maine), latest, p_dem_win: 0.70)
    forecast_for(races(:senate_maine), on_target, p_dem_win: 0.50) # +20pp from here: expected
    forecast_for(races(:senate_maine), closer_decoy, p_dem_win: 0.05) # +65pp if picked: wrong
    forecast_for(races(:senate_maine), farther_decoy, p_dem_win: 0.10) # +60pp if picked: wrong

    movers = Site::Movers.call

    mover = movers.find { |m| m.race == races(:senate_maine) }
    assert_in_delta 20.0, mover.delta_pp, 1e-9
  end

  test "excludes a race whose movement is below the noise floor, keeps one that clears it" do
    latest = create_run(started_at: "2026-08-08 12:00:00")
    previous = create_run(started_at: latest.started_at - WINDOW_DAYS.days)

    forecast_for(races(:senate_maine), latest, p_dem_win: 0.500)
    forecast_for(races(:senate_maine), previous, p_dem_win: 0.500 - (FLOOR_PP / 100.0) + 0.001) # just under the floor

    forecast_for(races(:senate_florida_special), latest, p_dem_win: 0.500)
    forecast_for(races(:senate_florida_special), previous, p_dem_win: 0.500 - (FLOOR_PP / 100.0) - 0.001) # just clears it

    movers = Site::Movers.call

    race_ids = movers.map { |m| m.race.id }
    assert_not_includes race_ids, races(:senate_maine).id
    assert_includes race_ids, races(:senate_florida_special).id
  end

  test "returns at most movers_count movers, largest absolute movement first" do
    latest = create_run(started_at: "2026-08-08 12:00:00")
    previous = create_run(started_at: latest.started_at - WINDOW_DAYS.days)

    # Eight races, all clearing the floor, with distinct deltas so the
    # ranking is unambiguous. Fixtures only give us three real races, so the
    # rest are created here — scoped to this test's transaction, invisible
    # to every other test (in particular, the Forecast::Runner goldens that
    # assume an exact fixture race count).
    deltas = [ 2.0, -3.0, 4.0, -5.0, 6.0, -7.0, 8.0, -9.0 ]
    races = Array.new(deltas.size) { |i| create_race("movers-count-#{i}") }

    races.each_with_index do |race, i|
      forecast_for(race, latest, p_dem_win: 0.50)
      forecast_for(race, previous, p_dem_win: 0.50 - (deltas[i] / 100.0))
    end

    movers = Site::Movers.call

    assert_equal COUNT, movers.size
    assert_equal movers.map { |m| m.delta_pp.abs }, movers.map { |m| m.delta_pp.abs }.sort.reverse
    assert_equal [ -9.0, 8.0, -7.0, 6.0, -5.0, 4.0 ], movers.map { |m| m.delta_pp.round(1) }
  end

  test "a race forecast only in the latest run (not the comparison run) is skipped, not crashed on" do
    latest = create_run(started_at: "2026-08-08 12:00:00")
    previous = create_run(started_at: latest.started_at - WINDOW_DAYS.days)

    forecast_for(races(:senate_maine), latest, p_dem_win: 0.60)
    forecast_for(races(:senate_maine), previous, p_dem_win: 0.40) # clears the floor, present in both

    new_race = create_race("movers-new-race")
    forecast_for(new_race, latest, p_dem_win: 0.90) # only in latest — no prior number to diff against

    movers = Site::Movers.call

    race_ids = movers.map { |m| m.race.id }
    assert_includes race_ids, races(:senate_maine).id
    assert_not_includes race_ids, new_race.id
  end

  test "Mover#direction reports which side gained" do
    latest = create_run(started_at: "2026-08-08 12:00:00")
    previous = create_run(started_at: latest.started_at - WINDOW_DAYS.days)

    forecast_for(races(:senate_maine), latest, p_dem_win: 0.70)
    forecast_for(races(:senate_maine), previous, p_dem_win: 0.50)
    forecast_for(races(:senate_florida_special), latest, p_dem_win: 0.30)
    forecast_for(races(:senate_florida_special), previous, p_dem_win: 0.50)

    movers = Site::Movers.call

    assert_equal :dem, movers.find { |m| m.race == races(:senate_maine) }.direction
    assert_equal :rep, movers.find { |m| m.race == races(:senate_florida_special) }.direction
  end

  private
    def create_run(started_at:)
      ModelRun.create!(status: :succeeded, trigger: :cron, started_at: started_at, finished_at: started_at)
    end

    def forecast_for(race, run, p_dem_win:)
      Forecast.create!(
        model_run: run, race: race,
        p_dem_win: p_dem_win, p_rep_win: 1.0 - p_dem_win, mean_margin: 0.0
      )
    end

    def create_race(slug)
      Race.create!(office: :senate, state: "ZZ", slug: slug, cycle: 2026)
    end
end
