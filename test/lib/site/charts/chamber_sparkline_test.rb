require "test_helper"

class Site::Charts::ChamberSparklineTest < ActiveSupport::TestCase
  def run_at(time, dem, rep = 1 - dem, snapshot = {})
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: time, params_snapshot: snapshot)
    ChamberForecast.create!(model_run: run, chamber: :senate, p_dem_control: dem, p_rep_control: rep, mean_dem_seats: 50)
    ChamberForecast.create!(model_run: run, chamber: :house, p_dem_control: 0.9, p_rep_control: 0.1, mean_dem_seats: 240)
    run
  end

  def build(variant: :excl_internals)
    Site::Charts::ChamberSparkline.build(Site::ChamberHistory.new(chamber: :senate), variant: variant)
  end

  # The fixture run is Aug 1 10:00 UTC; the axis ends Nov 3 05:00 UTC
  # (midnight Eastern, election day). 2,251 hours apart, so 1,125.5 hours
  # in — Sep 17 07:30 UTC — is the middle. The plot is 200 wide and 64 tall
  # with 3 of padding, so y = 3 + (1 - p) * 58.
  test "x runs from the first run to election day, y from 100% at the top to 0% at the bottom" do
    run_at(Time.utc(2026, 9, 17, 7, 30), 1.0, 0.0)

    sparkline = build

    assert_equal [ [ 0.0, 29.1 ], [ 100.0, 3.0 ] ], sparkline[:dem][:points]
    assert_equal [ [ 0.0, 34.9 ], [ 100.0, 61.0 ] ], sparkline[:rep][:points]
    assert_equal "M0,29.1L100,3", sparkline[:dem][:path]
    assert_equal({ left_pct: 50.0, top: 3.0 }, sparkline[:dem][:end])
    assert_equal 32.0, sparkline[:midline_y]
  end

  # Five runs inside one pixel column (a few minutes apart): drawing every
  # one is wasted bytes, but averaging them would erase the spike. The
  # column keeps its first, lowest, highest and last run, in the order they
  # happened: the extremes keep the spike, and the ends keep the line
  # starting and finishing on real runs.
  test "runs that share a pixel column keep that column's first, lowest, highest and last" do
    start = Time.utc(2026, 9, 17, 7, 30)
    [ 0.5, 0.5, 0.9, 0.5, 0.6 ].each_with_index { |dem, i| run_at(start + i.minutes, dem) }

    points = build[:dem][:points]

    # The fixture run, then 0.5 (first and lowest), 0.9 (highest), 0.6 (last).
    assert_equal [ 32.0, 8.8, 26.2 ], points.drop(1).map(&:last)
  end

  # The dot is the figure printed above it, so it must be the latest run,
  # not whichever extreme of the last column happened later.
  test "the line ends on the latest run even when that run is neither high nor low" do
    start = Time.utc(2026, 9, 17, 7, 30)
    [ 0.5, 0.9, 0.6 ].each_with_index { |dem, i| run_at(start + i.minutes, dem) }

    assert_equal 26.2, build[:dem][:end][:top]
  end

  # Unlabelled on the card itself; each mark names itself on hover.
  test "a correction is marked at the x of the run it lands on, with its date" do
    run_at(Time.utc(2026, 9, 17, 7, 30), 0.6, 0.4, { "poll_input_revision" => "candidates-v2" })

    assert_equal [ { x: 100.0, label: "Data correction, Sep 17" } ], build[:corrections]
  end

  test "the start is labelled with its date and both parties' values, in the site's words" do
    run_at(Time.utc(2026, 9, 17, 7, 30), 0.6921, 0.3046)

    sparkline = build

    assert_equal "Aug 1", sparkline[:start_label]
    assert_equal "55%", sparkline[:dem][:start_label]
    assert_equal "45%", sparkline[:rep][:start_label]
    assert_equal "Chance of Senate control in each model run since Aug 1: Democrats from 55% to 69%, " \
      "Republicans from 45% to 30%.", sparkline[:aria_label]
  end

  test "the internals view draws its own line" do
    ChamberForecast.create!(model_run: model_runs(:model_run_one), chamber: :senate, variant: :incl_internals,
      p_dem_control: 1.0, p_rep_control: 0.0, mean_dem_seats: 52)

    assert_equal [ [ 0.0, 3.0 ] ], build(variant: :incl_internals)[:dem][:points]
  end

  test "no runs, no sparkline" do
    ChamberForecast.delete_all

    assert_nil build
  end
end
