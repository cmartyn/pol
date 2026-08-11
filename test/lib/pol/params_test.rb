require "test_helper"

class Pol::ParamsTest < ActiveSupport::TestCase
  test "fetch! reads a real key from model_params.yml" do
    assert_equal 14, Pol::Params.fetch!(:averaging, :half_life_days)
  end

  test "fetch! raises a descriptive KeyError on an unknown top-level key" do
    error = assert_raises(KeyError) { Pol::Params.fetch!(:not_a_real_section) }
    assert_match(/not_a_real_section/, error.message)
  end

  test "fetch! raises a descriptive KeyError on an unknown nested key" do
    error = assert_raises(KeyError) { Pol::Params.fetch!(:averaging, :not_a_real_key) }
    assert_match(/not_a_real_key/, error.message)
  end

  # writer_model is the stand-in for "a param a later phase still has to fill";
  # it stays null until Phase 5 verifies an OpenRouter slug.
  test "fetch! raises KeyError on a nil value by default" do
    assert_raises(KeyError) { Pol::Params.fetch!(:newsroom, :writer_model) }
  end

  test "fetch! returns nil when allow_nil is true" do
    assert_nil Pol::Params.fetch!(:newsroom, :writer_model, allow_nil: true)
  end

  # Phase 2 verified these three against the sources recorded in
  # docs/BUILD_NOTES.md; the forecast engine reads them without allow_nil, so a
  # regression to null has to fail here rather than at model-run time.
  test "the Phase 2 fundamentals are filled in with verified numbers" do
    assert_in_delta(-1.5, Pol::Params.fetch!(:fundamentals, :pres_national_margin_2024))
    assert_in_delta 4.5, Pol::Params.fetch!(:fundamentals, :pres_national_margin_2020)
    assert_in_delta(-2.6, Pol::Params.fetch!(:fundamentals, :house_national_margin_2024))
  end

  # The holdover counts and the tiebreak decide chamber control before a single
  # seat is simulated, so a typo here is a wrong forecast, not a wrong number.
  # docs/BUILD_NOTES.md Phase 2 §A2 has the arithmetic: 31 + 34 + 35 = 100.
  test "the Phase 3 chamber constants match the verified holdover arithmetic" do
    assert_equal 34, Pol::Params.fetch!(:chambers, :senate_holdover_dem_caucus)
    assert_equal 31, Pol::Params.fetch!(:chambers, :senate_holdover_rep)
    assert_equal 100, Pol::Params.fetch!(:chambers, :senate_holdover_dem_caucus) +
      Pol::Params.fetch!(:chambers, :senate_holdover_rep) + 35
    assert_equal "rep", Pol::Params.fetch!(:chambers, :vp_party)
    assert_equal 218, Pol::Params.fetch!(:chambers, :house_majority_seats)
  end

  test "the error model carries a sigma for every draw the simulator makes" do
    %i[sigma_national sigma_state_polled sigma_state_unpolled sigma_district].each do |key|
      assert_operator Pol::Params.fetch!(:error_model, key), :>, 0
    end
    assert_operator Pol::Params.fetch!(:error_model, :sigma_state_unpolled), :>,
                    Pol::Params.fetch!(:error_model, :sigma_state_polled)
  end

  test "to_h returns the full deeply-symbolized params tree" do
    hash = Pol::Params.to_h
    assert_kind_of Hash, hash
    assert_equal 45, hash.dig(:averaging, :window_days)
  end

  test "reload! re-reads the file into a new hash with the same content" do
    original = Pol::Params.to_h
    reloaded = Pol::Params.reload!

    assert_equal original, reloaded
    refute_same original, reloaded
  end
end
