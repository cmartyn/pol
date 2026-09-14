require "test_helper"

class Newsroom::MovementTest < ActiveSupport::TestCase
  setup do
    @race = races(:senate_maine)
    @other_race = races(:senate_florida_special)
    # model_run_one already carries a Maine forecast at p_dem_win 0.62.
    @latest = model_runs(:model_run_one)
  end

  def earlier_run(days_before:, p_dem_win:, race: @race)
    started_at = days_before.days.before(@latest.started_at)
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: started_at, finished_at: started_at)
    Forecast.create!(model_run: run, race: race, p_dem_win: p_dem_win, p_rep_win: 1 - p_dem_win, mean_margin: 0.0)
    run
  end

  # A movement note the newsroom wrote about `race` from `run`.
  def note_from(run, race: @race, status: :published)
    Dispatch.create!(kind: :movement_note, race: race, model_run: run, status: status,
                     published_at: run.started_at + 1.hour, headline: "#{race.name} moved", body_markdown: "Body.")
  end

  test "with no earlier run there is nothing to compare and nothing to say" do
    assert_nil Newsroom::Movement.call(model_run: @latest)
  end

  test "a race that moved past the threshold is reported with its delta" do
    previous = earlier_run(days_before: 7, p_dem_win: 0.50)

    comparison = Newsroom::Movement.call(model_run: @latest)

    assert_equal previous, comparison.previous_run
    moved = comparison.races.sole
    assert_equal @race, moved.race
    assert_equal previous, moved.baseline_run
    assert_in_delta 0.12, moved.delta
    assert_in_delta 12.0, moved.delta_pp
  end

  # 0.62 − 0.54 is 0.07999999999999996 in binary floating point, so this is
  # also the test that a race which moved exactly eight points is a mover
  # rather than a victim of how doubles are stored (Movement::PROBABILITY_PLACES).
  test "the threshold is inclusive at the edge and exclusive one simulated draw under it" do
    assert_in_delta 0.08, Pol::Params.fetch!(:newsroom, :movement_threshold)

    at_edge = earlier_run(days_before: 7, p_dem_win: 0.54)
    assert_equal 1, Newsroom::Movement.call(model_run: @latest).races.size

    at_edge.forecasts.sole.update!(p_dem_win: 0.5401)
    assert_empty Newsroom::Movement.call(model_run: @latest).races
  end

  test "movement in the Republican direction counts the same" do
    earlier_run(days_before: 7, p_dem_win: 0.85)

    moved = Newsroom::Movement.call(model_run: @latest).races.sole
    assert_in_delta(-0.23, moved.delta)
  end

  test "the threshold is the one in model_params.yml" do
    earlier_run(days_before: 7, p_dem_win: 0.60)

    assert_empty Newsroom::Movement.call(model_run: @latest).races

    with_params(newsroom: { movement_threshold: 0.01 }) do
      assert_equal 1, Newsroom::Movement.call(model_run: @latest).races.size
    end
  end

  # Same selection the dashboard's movers module makes (ModelRun.comparison_run):
  # the succeeded run *closest* to the window, so a short run history still
  # produces a comparison instead of nothing.
  test "the comparison run is the succeeded run closest to the movers window" do
    earlier_run(days_before: 1, p_dem_win: 0.61)
    week_ago = earlier_run(days_before: 6, p_dem_win: 0.30)
    earlier_run(days_before: 30, p_dem_win: 0.10)

    comparison = Newsroom::Movement.call(model_run: @latest)

    assert_equal week_ago, comparison.previous_run
    assert_in_delta 0.32, comparison.races.sole.delta
  end

  test "a failed run is never the comparison" do
    good = earlier_run(days_before: 7, p_dem_win: 0.50)
    bad = ModelRun.create!(status: :failed, trigger: :cron, started_at: 7.days.before(@latest.started_at))
    Forecast.create!(model_run: bad, race: @race, p_dem_win: 0.05, p_rep_win: 0.95, mean_margin: -30.0)

    assert_equal good, Newsroom::Movement.call(model_run: @latest).previous_run
  end

  test "races the two runs do not share are skipped rather than treated as movement" do
    previous = earlier_run(days_before: 7, p_dem_win: 0.50)
    Forecast.create!(model_run: previous, race: @other_race, p_dem_win: 0.10, p_rep_win: 0.90, mean_margin: -20.0)

    assert_equal [ @race ], Newsroom::Movement.call(model_run: @latest).races.map(&:race)
  end

  test "the biggest mover is first, so a cap that bites drops the smallest story" do
    previous = earlier_run(days_before: 7, p_dem_win: 0.50)
    Forecast.create!(model_run: previous, race: @other_race, p_dem_win: 0.90, p_rep_win: 0.10, mean_margin: 20.0)
    Forecast.create!(model_run: @latest, race: @other_race, p_dem_win: 0.20, p_rep_win: 0.80, mean_margin: -12.0)

    assert_equal [ @other_race, @race ], Newsroom::Movement.call(model_run: @latest).races.map(&:race)
  end

  test "movement reads only the published variant, never the internals one" do
    previous = earlier_run(days_before: 7, p_dem_win: 0.62)
    # A wild swing that exists only in the internals variant of both runs —
    # the published (excl) rows are identical, so nothing moved.
    Forecast.create!(model_run: previous, race: @race, variant: :incl_internals,
                     p_dem_win: 0.10, p_rep_win: 0.90, mean_margin: 0.0)
    Forecast.create!(model_run: @latest, race: @race, variant: :incl_internals,
                     p_dem_win: 0.90, p_rep_win: 0.10, mean_margin: 0.0)

    assert_empty Newsroom::Movement.call(model_run: @latest).races
  end

  # The cooldown ramps down toward election day (Newsroom::Caps), and a
  # shorter cooldown against a fixed seven-day window would re-tell the same
  # move every run for as long as it stayed inside the window. So a race the
  # newsroom has already written up is measured from the run that note was
  # written from: the reader has been told about everything before it.
  test "a race written up since the comparison run is measured from its note's run, not from last week" do
    earlier_run(days_before: 7, p_dem_win: 0.30)
    note_from earlier_run(days_before: 3, p_dem_win: 0.60)

    assert_empty Newsroom::Movement.call(model_run: @latest).races
  end

  test "new movement since the last note is reported against that note's run" do
    week_ago = earlier_run(days_before: 7, p_dem_win: 0.30)
    noted = earlier_run(days_before: 3, p_dem_win: 0.50)
    note_from noted

    comparison = Newsroom::Movement.call(model_run: @latest)
    moved = comparison.races.sole
    assert_equal noted, moved.baseline_run
    assert_in_delta 0.12, moved.delta
    assert_equal week_ago, comparison.previous_run, "the week-ago comparison run is unchanged; only this race's baseline moved"
  end

  # Same rule as the cooldown's (Caps): an editor who pulled the piece must
  # not get it regenerated, so a retracted note still sets the baseline.
  test "a retracted note still sets the baseline, so a pulled piece is not regenerated" do
    earlier_run(days_before: 7, p_dem_win: 0.30)
    note_from earlier_run(days_before: 3, p_dem_win: 0.60), status: :retracted

    assert_empty Newsroom::Movement.call(model_run: @latest).races
  end

  test "a note older than the comparison run does not reach back past it" do
    note_from earlier_run(days_before: 20, p_dem_win: 0.10)
    week_ago = earlier_run(days_before: 7, p_dem_win: 0.30)

    moved = Newsroom::Movement.call(model_run: @latest).races.sole
    assert_equal week_ago, moved.baseline_run
    assert_in_delta 0.32, moved.delta
  end

  test "a note with no run recorded cannot be measured from, so the comparison run stays the baseline" do
    week_ago = earlier_run(days_before: 7, p_dem_win: 0.30)
    Dispatch.create!(kind: :movement_note, race: @race, status: :published,
                     published_at: 2.days.before(@latest.started_at), headline: "Maine moved", body_markdown: "Body.")

    moved = Newsroom::Movement.call(model_run: @latest).races.sole
    assert_equal week_ago, moved.baseline_run
  end

  test "a note whose run has no forecast for the race cannot be measured from either" do
    week_ago = earlier_run(days_before: 7, p_dem_win: 0.30)
    note_from earlier_run(days_before: 3, p_dem_win: 0.60, race: @other_race)

    moved = Newsroom::Movement.call(model_run: @latest).races.sole
    assert_equal week_ago, moved.baseline_run
  end

  test "baselines are per race: one race's note does not silence another race's move" do
    week_ago = earlier_run(days_before: 7, p_dem_win: 0.30)
    Forecast.create!(model_run: week_ago, race: @other_race, p_dem_win: 0.10, p_rep_win: 0.90, mean_margin: -20.0)
    Forecast.create!(model_run: @latest, race: @other_race, p_dem_win: 0.40, p_rep_win: 0.60, mean_margin: -3.0)
    note_from earlier_run(days_before: 3, p_dem_win: 0.60)

    moved = Newsroom::Movement.call(model_run: @latest).races.sole
    assert_equal @other_race, moved.race
    assert_equal week_ago, moved.baseline_run
  end

  # A job retried after a crash mid-loop sees the notes it already wrote from
  # this very run: measured from it, nothing has moved, and nothing is redone.
  test "a note already written from this run means there is nothing new to say" do
    earlier_run(days_before: 7, p_dem_win: 0.30)
    note_from @latest

    assert_empty Newsroom::Movement.call(model_run: @latest).races
  end
end
