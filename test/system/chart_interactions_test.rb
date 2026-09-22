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
    within "[data-testid=map-senate]" do
      find("a[data-key='ME'] path").click
    end

    assert_current_path race_path(races(:senate_maine).slug)
    assert_equal "kept", evaluate_script("window.__mapVisit")
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
