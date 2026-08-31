require "application_system_test_case"

# The internals toggle end to end, in a real browser: the header switch flips
# html[data-internals], the CSS swaps which variant's markup shows, the
# preference survives a navigation via localStorage, and the shareable-link
# fragment forces the internals view on. Fixture data only — both variants
# render identical numbers here (no fixture poll is flagged), so these prove
# the switching machinery, not the model.
class InternalsToggleTest < ApplicationSystemTestCase
  test "the switch swaps variants, persists, and honors the share fragment" do
    visit root_path

    # Default: the published view shows, the internals view is hidden.
    assert_selector "[data-testid=national-environment] [data-variant=excl_internals]", visible: :visible
    assert_selector "[data-testid=national-environment] [data-variant=incl_internals]", visible: :hidden

    find("[data-testid=internals-toggle]").click

    assert_selector "[data-testid=national-environment] [data-variant=incl_internals]", visible: :visible
    assert_selector "[data-testid=national-environment] [data-variant=excl_internals]", visible: :hidden

    # The preference follows the reader to the next page.
    visit senate_path
    assert_selector "[data-testid=senate-table] [data-variant=incl_internals]", visible: :visible

    # And off again.
    find("[data-testid=internals-toggle]").click
    assert_selector "[data-testid=senate-table] [data-variant=excl_internals]", visible: :visible
  end

  test "a shared link's fragment turns the internals view on for the visit" do
    visit root_path(anchor: "internals=on")

    assert_selector "[data-testid=national-environment] [data-variant=incl_internals]", visible: :visible
    assert_selector "[data-testid=internals-toggle] input", visible: :all
    assert find("[data-testid=internals-toggle] input", visible: :all).checked?
  end
end
