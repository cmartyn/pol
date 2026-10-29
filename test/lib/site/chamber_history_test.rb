require "test_helper"

class Site::ChamberHistoryTest < ActiveSupport::TestCase
  # A succeeded run with a forecast for each chamber. `incl` adds an
  # internals row for the Senate; runs from before the dual-variant model
  # have none.
  def run_at(time, snapshot = {}, senate: [ 0.5, 0.5, 50.0 ], house: [ 0.9, 0.1, 240.0 ], incl: nil, status: :succeeded)
    run = ModelRun.create!(status: status, trigger: :cron, started_at: time, params_snapshot: snapshot)
    { senate: senate, house: house }.each do |chamber, (dem, rep, seats)|
      ChamberForecast.create!(model_run: run, chamber: chamber, p_dem_control: dem, p_rep_control: rep, mean_dem_seats: seats)
    end
    if incl
      ChamberForecast.create!(model_run: run, chamber: :senate, variant: :incl_internals,
        p_dem_control: incl[0], p_rep_control: incl[1], mean_dem_seats: incl[2])
    end
    run
  end

  test "entries are this chamber's succeeded runs, oldest first" do
    later = run_at("2026-09-10 08:00:00", senate: [ 0.41, 0.58, 49.8 ])
    run_at("2026-09-11 08:00:00", status: :failed)
    earlier = run_at("2026-08-20 08:00:00", senate: [ 0.47, 0.52, 50.1 ])

    entries = Site::ChamberHistory.new(chamber: :senate).entries

    # model_run_one (Aug 1, fixture: 55%) comes first.
    assert_equal [ model_runs(:model_run_one), earlier, later ].map(&:id), entries.map { |entry| entry.run.id }
    assert_equal [ 0.55, 0.47, 0.41 ], entries.map { |entry| entry.excl.p_dem }
    assert_equal [ 51.2, 50.1, 49.8 ], entries.map { |entry| entry.excl.mean_seats }
  end

  test "the House history reads House rows, not the Senate's" do
    run_at("2026-08-20 08:00:00", house: [ 0.93, 0.07, 242.2 ])

    entries = Site::ChamberHistory.new(chamber: :house).entries

    assert_equal [ 0.48, 0.93 ], entries.map { |entry| entry.excl.p_dem }
  end

  test "the internals view falls back to the published row where a run wrote none" do
    run_at("2026-09-01 08:00:00", senate: [ 0.50, 0.49, 50.3 ], incl: [ 0.53, 0.46, 50.6 ])

    entries = Site::ChamberHistory.new(chamber: :senate).entries

    assert_equal [ 0.55, 0.53 ], entries.map { |entry| entry.incl.p_dem }
    assert_equal [ 0.55, 0.50 ], entries.map { |entry| entry.excl.p_dem }
  end

  test "seat histograms load only when asked for" do
    assert_nil Site::ChamberHistory.new(chamber: :senate).entries.first.excl.histogram
    assert_equal 0.30, Site::ChamberHistory.new(chamber: :senate, seats: true).entries.first.excl.histogram["52"]
  end

  # Production on 2026-10-23..26: a pollster excluded, then House baselines
  # redrawn, then poll records repaired. The redistricting fix touched no
  # Senate input, so it must not mark the Senate chart.
  test "corrections land on the first run after an input change, and only where they touch the chamber" do
    excluded = { "excluded_pollsters" => [ { "id" => 7 } ] }
    redrawn = excluded.merge("house_baselines" => { "revision" => "pres-2024-lines-v1" })
    repaired = redrawn.merge("poll_input_revision" => "candidates-v2")
    run_at("2026-10-23 08:00:00")
    exclusion = run_at("2026-10-23 14:00:00", excluded)
    redraw = run_at("2026-10-25 20:42:00", redrawn)
    run_at("2026-10-25 22:30:00", redrawn)
    repair = run_at("2026-10-26 09:04:00", repaired)

    senate = Site::ChamberHistory.new(chamber: :senate).corrections
    house = Site::ChamberHistory.new(chamber: :house).corrections

    assert_equal [ exclusion, repair ].map(&:id), senate.map { |correction| correction.run.id }
    assert_equal [ [ :pollster_exclusions ], [ :poll_inputs ] ], senate.map(&:kinds)
    assert_equal [ exclusion, redraw, repair ].map(&:id), house.map { |correction| correction.run.id }
    assert_equal [ :house_baselines ], house.second.kinds
    # index is the entry the correction lands on, for the chart's readout.
    entries = Site::ChamberHistory.new(chamber: :house).entries
    assert_equal redraw.id, entries[house.second.index].run.id
  end

  test "no chamber forecasts, no entries and no corrections" do
    ChamberForecast.delete_all

    history = Site::ChamberHistory.new(chamber: :senate)

    assert history.empty?
    assert_equal [], history.corrections
  end
end
