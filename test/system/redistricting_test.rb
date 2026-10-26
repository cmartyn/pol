require "application_system_test_case"

class RedistrictingTest < ApplicationSystemTestCase
  test "a redrawn district shows its sourced baseline and labels corrected history on mobile" do
    race = Race.create!(office: :house, state: "TN", district: 9, cycle: 2026,
      slug: "house-2026-tn-09", baseline_margin: 45.6, baseline_imputed: true)
    Forecast.create!(race: race, model_run: model_runs(:model_run_one), variant: :excl_internals,
      p_dem_win: 1, p_rep_win: 0, p_other_win: 0, mean_margin: 56.8)
    Forecast::Runner.call(trigger: :manual, as_of: Date.new(2026, 10, 25), seed: 42, n_sims: 1000)

    page.current_window.resize_to(375, 812)
    visit race_path(race.slug)
    assert_selector "[data-testid='forecast-baseline']", text: "R+21.1"
    assert_selector "[data-testid='forecast-baseline']", text: "D+45.6"
    assert_link "Source: The Downballot"
    assert_selector "[data-testid='baseline-correction-note']", text: "model changes"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")

    visit house_path
    within "[data-testid='house-race-row']", text: "TN-9" do
      assert_text "President · new lines"
      assert_text "R+21.1"
      assert_no_selector "[data-testid='baseline-imputed-marker']"
    end
  end
end
