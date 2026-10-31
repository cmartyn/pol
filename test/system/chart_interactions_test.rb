require "application_system_test_case"

# The charts' interaction layer, in a real browser: hover produces a readout,
# keyboard scrubbing produces the same one, and the axis labels say the things
# the payload promised. Unit tests prove the payload strings; these prove a
# pointer can actually reach them — the capture rect really sits on top, the
# tooltip really unhides, the ResizeObserver really rendered before anyone
# hovered. Fixture data only; no network, no model run.
#
# The axis assertions double as regression guards for the original label bug:
# d3-axis's default multi-scale time format printed "12 PM / Wed 12" on a
# short run history. SVG axis text must never contain a bare clock time, and
# the first tick must anchor its year.
class ChartInteractionsTest < ApplicationSystemTestCase
  setup do
    @race = races(:senate_maine)
  end

  test "timeline: hover and arrow keys read out a model run, axis has no clock-time labels" do
    visit race_path(@race.slug)

    within "[data-testid=timeline-chart]" do
      # One fixture run → the single-point degenerate path: a dot, padded
      # domain, still hoverable.
      find("svg").hover
      assert_selector "[data-testid=chart-tooltip]", text: "Aug 1, 2026 · 6:00 AM EDT"
      assert_selector "[data-testid=chart-tooltip]", text: "62%"

      # Axis text: anchored ("…, 2026" somewhere) and free of hour labels.
      assert_selector "svg text", text: /\d{4}/
      assert_no_selector "svg text", text: /\d+\s?(AM|PM)\b/
    end

    # Same readout without a pointer: focus the chart, step with arrows.
    chart = find("[data-testid=timeline-chart] [tabindex='0']")
    chart.send_keys :arrow_left
    within "[data-testid=timeline-chart]" do
      assert_selector "[data-testid=chart-tooltip]", text: "6:00 AM EDT"
      # The tooltip is aria-hidden; a screen reader hears the step here.
      assert_selector "[data-testid=timeline-status]", text: "Aug 1, 2026 · 6:00 AM EDT: Dem 62%, Rep 38%", visible: :all
      # One run: no range to switch, and the summary is for screen readers only.
      assert_selector "[data-testid=timeline-range-recent]", visible: :hidden
      assert_selector "[data-testid=timeline-summary].sr-only", visible: :all
    end
  end

  # Two-hourly runs since August put ~680 arrow presses between a reader and
  # Oct 1. The chart opens on the last 30 days; Page Up/Down move a day and
  # Shift+arrow a week.
  test "timeline: opens on the last 30 days, steps by day and by week, and reads each step out" do
    start = Time.zone.parse("2026-08-02 06:00")
    120.times do |i|
      run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: start + (i * 12).hours,
                             params_snapshot: model_runs(:model_run_one).params_snapshot)
      Forecast.create!(model_run: run, race: @race, p_dem_win: 0.6, p_rep_win: 0.4, mean_margin: 3.0)
    end

    visit race_path(@race.slug)

    status = "[data-testid=timeline-status]"
    assert_selector "[data-testid=timeline-range-recent][aria-pressed=true]", text: "Last 30 days"
    plot = find("[data-testid=timeline-chart] [tabindex='0']")
    plot.send_keys :end
    assert_selector status, text: "Sep 30, 2026 · 6:00 PM EDT", visible: :all
    plot.send_keys :page_up
    assert_selector status, text: "Sep 29, 2026 · 6:00 PM EDT", visible: :all
    # A week back lands in the thinned history, on the day's kept run.
    plot.send_keys [ :shift, :arrow_left ]
    assert_selector status, text: "Sep 22, 2026 · 6:00 AM EDT", visible: :all
    plot.send_keys :home
    assert_selector status, text: "Sep 1, 2026 · 6:00 AM EDT", visible: :all

    click_button "Full season"
    assert_selector "[data-testid=timeline-range-all][aria-pressed=true]"
    plot.send_keys :home
    assert_selector status, text: "Aug 1, 2026 · 6:00 AM EDT", visible: :all
  end

  # Two panels on one time axis: hover and the arrow keys read out a run's
  # chance of control and expected seats together, the run after a
  # correction says so, and the axis ends at election day.
  test "chamber timeline: a run reads out control and seats, and a correction names itself" do
    corrected = ModelRun.create!(status: :succeeded, trigger: :manual, started_at: "2026-10-26 09:04:00",
      params_snapshot: { "poll_input_revision" => "candidates-v2" })
    ChamberForecast.create!(model_run: corrected, chamber: :senate, p_dem_control: 0.61, p_rep_control: 0.39,
      mean_dem_seats: 51.1, seat_histogram: { "49" => 5, "50" => 20, "51" => 45, "52" => 25, "53" => 5 })
    ChamberForecast.create!(model_run: corrected, chamber: :house, p_dem_control: 0.97, p_rep_control: 0.03, mean_dem_seats: 243)

    visit senate_path

    within "[data-testid=chamber-timeline]" do
      assert_selector "svg text", text: "Election Day"
      assert_selector "svg text", text: "Correction"
      assert_selector "svg text", text: "51 = majority"
      assert_no_selector "svg text", text: /\d+\s?(AM|PM)\b/

      # Focus shows the latest run, which is the first after the correction.
      find("[tabindex='0']").send_keys :end
      assert_selector "[data-testid=chart-tooltip]", text: "Oct 26, 2026 · 9:04 AM EDT"
      assert_selector "[data-testid=chart-tooltip]", text: "61%"
      assert_selector "[data-testid=chart-tooltip]", text: "51.1"
      assert_selector "[data-testid=chart-tooltip]", text: "First run after a data correction"
      assert_selector "[data-testid=chart-tooltip]", text: "49–52"
      assert_selector "[aria-live=polite]", text: /Oct 26, 2026 · 9:04 AM EDT.*Dem 61%.*Rep 39%.*51\.1/, visible: :all

      find("[tabindex='0']").send_keys :arrow_left
      assert_selector "[data-testid=chart-tooltip]", text: "Aug 1, 2026 · 6:00 AM EDT"
      assert_no_selector "[data-testid=chart-tooltip]", text: "data correction"

      find("svg").hover
      assert_selector "[data-testid=chart-tooltip]", text: /expected Dem-caucus seats/

      # 51.1 expected seats sits on the 51-seat majority line. The dashed
      # line must break around the end label, or "51.1" reads as "-51.1".
      crosses_label = page.evaluate_script(<<~JS)
        (() => {
          const svg = document.querySelector("[data-testid=chamber-timeline] svg")
          const label = svg.querySelector("[data-testid=chamber-timeline-seats-label]").getBBox()
          return [...svg.querySelectorAll("[data-testid=chamber-timeline-majority]")].some((line) =>
            +line.getAttribute("x1") < label.x + label.width + 1 && +line.getAttribute("x2") > label.x - 1)
        })()
      JS
      assert_equal false, crosses_label
    end
  end

  test "polls scatter: hovering a dot names the pollster, margin, dates and sample" do
    visit race_path(@race.slug)

    within "[data-testid=polls-scatter-chart]" do
      # Hovering the circle moves the pointer to its center; the capture rect
      # on top receives the event and snaps to the nearest point — which is
      # exactly the interaction a reader gets.
      all("svg circle").last.hover
      assert_selector "[data-testid=chart-tooltip]", text: /Beacon Polling|Cardinal Research/
      assert_selector "[data-testid=chart-tooltip]", text: /[DR]\+\d|Even/
      assert_selector "[data-testid=chart-tooltip]", text: /\d{3} (LV|RV)/

      # Party-anchored y-axis and a year-anchored x-axis.
      assert_selector "svg text", text: /^Even$/
      assert_selector "svg text", text: /\d{4}/
    end
  end

  test "seat histogram: hover reads out a bin, majority line and ticks are labeled" do
    visit root_path

    within "[data-testid=seat-histogram-senate]" do
      find("svg").hover
      assert_selector "[data-testid=chart-tooltip]", text: /\d+ Dem-caucus seats/
      assert_selector "[data-testid=chart-tooltip]", text: /%\s*of simulations/
      # vp_party is "rep" in model_params.yml, so Democrats need 51 outright.
      assert_text "51 = majority"
    end

    # House ticks land on clean multiples inside the fixture's 210–225 range.
    within "[data-testid=seat-histogram-house]" do
      assert_text "215"
      assert_text "218 = majority"
    end
  end

  test "senate map: hovering a state reads out its race, and the internals toggle recolors it" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "FL", box: [ -87.6, 24.5, -80.0, 31.0 ])
    Forecast.create!(model_run: model_runs(:model_run_one), race: races(:senate_maine), variant: :incl_internals,
                     p_dem_win: 0.2, p_rep_win: 0.8, p_other_win: 0.0, mean_margin: -6.0)

    visit senate_path

    within "[data-testid=map-senate]" do
      find("a[data-key='ME'] path").hover
      assert_selector "[data-testid=chart-tooltip]", text: "Maine Senate"
      assert_selector "[data-testid=chart-tooltip]", text: "62%"
    end

    fill = "getComputedStyle(document.querySelector(\"[data-testid=map-senate] a[data-key='ME'] path\")).fill"
    published = evaluate_script(fill)
    find("[data-testid=internals-toggle]").click
    assert_selector "html[data-internals='on']", visible: :all
    assert_not_equal published, evaluate_script(fill)
  end

  test "senate map: clicking a state is a Turbo visit, not a full page load" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])

    visit senate_path
    execute_script("window.__mapVisit = 'kept'")
    execute_script("window.__mapErrors = []; window.addEventListener('error', (event) => window.__mapErrors.push(event.message))")
    within "[data-testid=map-senate]" do
      find("a[data-key='ME'] path").click
    end

    assert_current_path race_path(races(:senate_maine).slug)
    assert_equal "kept", evaluate_script("window.__mapVisit")
    assert_equal [], evaluate_script("window.__mapErrors")
  end

  test "senate map: hovering a no-race state shows no readout" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "VT", box: [ -73.4, 42.7, -71.5, 45.0 ])

    visit senate_path
    within "[data-testid=map-senate]" do
      find("path[data-key='VT']").hover
      assert_no_selector "[data-testid=chart-tooltip]", visible: :visible
    end
  end
end
