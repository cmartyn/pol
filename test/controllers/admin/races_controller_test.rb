require "test_helper"

class Admin::RacesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  # --- index -----------------------------------------------------------------

  test "index lists every race" do
    get admin_races_path
    assert_response :success
    assert_select "[data-testid='admin-race-row']", count: Race.count
  end

  test "index filters by office" do
    get admin_races_path, params: { office: "house" }
    assert_select "[data-testid='admin-race-row']", count: Race.house.count
  end

  test "index searches by state code" do
    get admin_races_path, params: { state: "ME" }
    assert_select "[data-testid='admin-race-row']", text: /#{Regexp.escape(races(:senate_maine).name)}/
    assert_select "[data-testid='admin-race-row']", count: Race.where(state: "ME").count
  end

  test "index searches by full state name" do
    get admin_races_path, params: { state: "Maine" }
    assert_select "[data-testid='admin-race-row']", text: /#{Regexp.escape(races(:senate_maine).name)}/
  end

  test "index shows the uncontested badge only on uncontested races" do
    races(:senate_maine).update!(uncontested: true, uncontested_party: :rep)
    get admin_races_path

    maine_row = css_select("[data-testid='admin-race-row']").find { |row| row.text.include?(races(:senate_maine).name) }
    assert maine_row.css("[data-testid='admin-race-uncontested-badge']").any?

    florida_row = css_select("[data-testid='admin-race-row']").find { |row| row.text.include?(races(:senate_florida_special).name) }
    assert_empty florida_row.css("[data-testid='admin-race-uncontested-badge']")
  end

  test "index shows the imputed badge for a House race with an imputed baseline" do
    races(:house_ny_17).update!(baseline_imputed: true)
    get admin_races_path
    assert_select "[data-testid='admin-race-imputed-badge']"
  end

  # --- edit/update -------------------------------------------------------------

  test "edit renders the form and the guardrail note" do
    get edit_admin_race_path(races(:senate_maine))
    assert_response :success
    assert_select "[data-testid='admin-race-form']"
    assert_select "[data-testid='admin-race-guardrail-note']", text: /next model run/
  end

  test "update persists every editable field" do
    patch admin_race_path(races(:senate_maine)), params: { race: {
      lean: "4.2", incumbent_name: "New Incumbent", incumbent_party: "dem",
      open_seat: "1", special: "0", uncontested: "1", uncontested_party: "rep"
    } }

    assert_redirected_to edit_admin_race_path(races(:senate_maine))
    race = races(:senate_maine).reload
    assert_in_delta 4.2, race.lean, 0.001
    assert_equal "New Incumbent", race.incumbent_name
    assert_equal "dem", race.incumbent_party
    assert race.open_seat?
    assert_not race.special?
    assert race.uncontested?
    assert_equal "rep", race.uncontested_party
  end

  test "update persists baseline_margin and baseline_imputed for a House race" do
    patch admin_race_path(races(:house_ny_17)), params: { race: { baseline_margin: "5.5", baseline_imputed: "1" } }

    race = races(:house_ny_17).reload
    assert_in_delta 5.5, race.baseline_margin, 0.001
    assert race.baseline_imputed?
  end

  test "update accepts a blank incumbent_party/uncontested_party without raising" do
    races(:senate_maine).update!(incumbent_party: :rep, uncontested_party: :rep)

    patch admin_race_path(races(:senate_maine)), params: { race: { incumbent_party: "", uncontested_party: "" } }

    assert_redirected_to edit_admin_race_path(races(:senate_maine))
    race = races(:senate_maine).reload
    assert_nil race.incumbent_party
    assert_nil race.uncontested_party
  end
end
