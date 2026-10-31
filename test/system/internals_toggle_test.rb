require "application_system_test_case"

# The internals toggle end to end, in a real browser: the header switch flips
# html[data-internals], the CSS swaps which variant's markup shows, the
# choice follows the reader through the visit via sessionStorage, and the
# shareable-link fragment forces the internals view on. Fixture data only —
# both variants render identical numbers here (no fixture poll is flagged),
# so these prove the switching machinery, not the model.
class InternalsToggleTest < ApplicationSystemTestCase
  test "the switch swaps variants, persists, and honors the share fragment" do
    visit root_path

    # Default: the published view shows, the internals view is hidden.
    assert_selector "[data-testid=national-environment] [data-variant=excl_internals]", visible: :visible
    assert_selector "[data-testid=national-environment] [data-variant=incl_internals]", visible: :hidden

    find("[data-testid=internals-toggle]").click

    assert_selector "[data-testid=national-environment] [data-variant=incl_internals]", visible: :visible
    assert_selector "[data-testid=national-environment] [data-variant=excl_internals]", visible: :hidden

    # The choice follows the reader to the next page.
    visit senate_path
    assert_selector "[data-testid=senate-table] [data-variant=incl_internals]", visible: :visible

    # And off again.
    find("[data-testid=internals-toggle]").click
    assert_selector "[data-testid=senate-table] [data-variant=excl_internals]", visible: :visible
  end

  # A race page says which forecast it shows while internals are on, and its
  # Turn off puts the published one back without a trip to the header.
  test "the race page's marker says internals are on, and Turn off returns the published forecast" do
    visit race_path(races(:senate_maine).slug)
    assert_selector "[data-testid=internals-marker]", visible: :hidden

    find("[data-testid=internals-toggle]").click
    assert_selector "[data-testid=internals-marker]", text: "Includes partisan internals.", visible: :visible
    assert_selector "[data-testid=chart-internals-tag]", visible: :visible
    assert_selector "[role=status]", text: "Partisan internals on.", visible: :all

    within("[data-testid=internals-marker]") { click_button "Turn off" }

    assert_selector "[data-testid=internals-marker]", visible: :hidden
    assert_selector "[data-testid=race-masthead] [data-variant=excl_internals]", visible: :visible
    assert_not find("[data-testid=internals-toggle] input", visible: :all).checked?
    assert_selector "[role=status]", text: "Partisan internals off.", visible: :all
  end

  # The choice lasts the visit, not the week: a reader who comes back days
  # later should not be greeted by a forecast the site does not publish.
  test "the choice is kept in session storage, not local storage" do
    visit root_path
    find("[data-testid=internals-toggle]").click

    assert_equal "on", page.evaluate_script("sessionStorage.getItem('pol-internals')")
    assert_nil page.evaluate_script("localStorage.getItem('pol-internals')")
  end

  test "flipping the switch keeps the page in Turbo's history, so Back still works" do
    visit root_path
    find("[data-testid=internals-toggle]").click
    assert_selector "[data-testid=national-environment] [data-variant=incl_internals]", visible: :visible

    within("nav[aria-label=Primary]") { click_link "Senate" }
    assert_selector "h1", text: "Senate"

    page.go_back
    assert_selector "h1", text: "2026 midterms forecast"
  end

  test "a shared link's fragment turns the internals view on for the visit" do
    visit root_path(anchor: "internals=on")

    assert_selector "[data-testid=national-environment] [data-variant=incl_internals]", visible: :visible
    assert_selector "[data-testid=internals-toggle] input", visible: :all
    assert find("[data-testid=internals-toggle] input", visible: :all).checked?
  end
end
