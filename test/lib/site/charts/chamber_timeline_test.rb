require "test_helper"

class Site::Charts::ChamberTimelineTest < ActiveSupport::TestCase
  def run_at(time, snapshot = {}, senate: [ 0.5, 0.5, 50.0 ], histogram: nil, incl: nil)
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: time, params_snapshot: snapshot)
    ChamberForecast.create!(model_run: run, chamber: :senate, p_dem_control: senate[0], p_rep_control: senate[1],
      mean_dem_seats: senate[2], seat_histogram: histogram)
    ChamberForecast.create!(model_run: run, chamber: :house, p_dem_control: 0.9, p_rep_control: 0.1, mean_dem_seats: 240)
    if incl
      ChamberForecast.create!(model_run: run, chamber: :senate, variant: :incl_internals,
        p_dem_control: incl[0], p_rep_control: incl[1], mean_dem_seats: incl[2], seat_histogram: histogram)
    end
    run
  end

  def build(chamber = :senate)
    Site::Charts::ChamberTimeline.build(Site::ChamberHistory.new(chamber: chamber, seats: true))
  end

  test "each run carries its time and both parties' odds in the site's whole-percent words" do
    run_at("2026-10-29 11:00:00", senate: [ 0.6921, 0.3046, 51.84 ])

    payload = build

    assert_equal [ "Aug 1, 2026 · 6:00 AM EDT", "Oct 29, 2026 · 11:00 AM EDT" ], payload[:time_labels]
    assert_equal Time.utc(2026, 10, 29, 15).to_i * 1000, payload[:t].last
    excl = payload[:series][:excl]
    assert_equal [ 0.55, 0.6921 ], excl[:dem]
    assert_equal [ "55%", "69%" ], excl[:dem_labels]
    assert_equal [ "45%", "30%" ], excl[:rep_labels]
    assert_equal [ "51.2", "51.8" ], excl[:seats_labels]
    refute payload[:sparse]
  end

  # Nearest rank, as Forecast::Simulator#percentile: the smallest seat count
  # at or below which p% of simulated elections fall. 100 draws here, so the
  # 5th sits at 49 (3 + 4 = 7 draws by then) and the 95th at 52 (95 by then).
  test "the seat range is the 5th to 95th percentile of each run's simulations" do
    run_at("2026-09-01 08:00:00", histogram: { "48" => 3, "49" => 4, "50" => 20, "51" => 50, "52" => 18, "53" => 5 })

    excl = build[:series][:excl]

    # The fixture run stores shares, not counts: 0.12 at 50 clears 5%, and
    # 95% is not reached until 54.
    assert_equal [ 50, 49 ], excl[:low]
    assert_equal [ 54, 52 ], excl[:high]
    assert_equal [ "50–54", "49–52" ], excl[:range_labels]
  end

  test "a run without a histogram has no seat range rather than a made-up one" do
    run_at("2026-09-01 08:00:00", histogram: nil)

    excl = build[:series][:excl]

    assert_nil excl[:low].last
    assert_nil excl[:high].last
    assert_nil excl[:range_labels].last
  end

  test "the internals view has its own series, aligned run for run" do
    run_at("2026-09-01 08:00:00", senate: [ 0.50, 0.49, 50.3 ], incl: [ 0.53, 0.46, 50.6 ])

    payload = build

    assert_equal [ "55%", "50%" ], payload[:series][:excl][:dem_labels]
    assert_equal [ "55%", "53%" ], payload[:series][:incl][:dem_labels]
  end

  # 2026-11-03 is after the clocks change, so midnight Eastern is 05:00 UTC.
  test "the time axis ends at the start of election day" do
    payload = build

    assert_equal Time.utc(2026, 11, 3, 5).to_i * 1000, payload[:election][:t]
    assert_equal "Election Day", payload[:election][:label]
  end

  test "each correction carries the position of the run it lands on and its date" do
    run_at("2026-10-26 08:00:00")
    run_at("2026-10-26 09:04:00", { "poll_input_revision" => "candidates-v2" })

    corrections = build[:corrections]

    assert_equal [ { index: 2, t: Time.utc(2026, 10, 26, 13, 4).to_i * 1000, label: "Oct 26" } ], corrections
  end

  test "the majority line sits at each chamber's Democratic control threshold" do
    # vp_party is "rep" in model_params.yml, so Democrats need 51 senators.
    assert_equal({ seats: 51, label: "51 = majority" }, build(:senate)[:majority])
    assert_equal({ seats: 218, label: "218 = majority" }, build(:house)[:majority])
  end

  test "one run is sparse" do
    assert build[:sparse]
  end
end
