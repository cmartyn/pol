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

  # Every parameter in the file is filled in as of Phase 5, so the nil rules
  # are exercised against a deliberately emptied one. A later phase that adds
  # a "fill this in next time" null gets the behaviour these two describe.
  test "fetch! raises KeyError on a nil value by default" do
    with_params(newsroom: { writer_model: nil }) do
      assert_raises(KeyError) { Pol::Params.fetch!(:newsroom, :writer_model) }
    end
  end

  test "fetch! returns nil when allow_nil is true" do
    with_params(newsroom: { writer_model: nil }) do
      assert_nil Pol::Params.fetch!(:newsroom, :writer_model, allow_nil: true)
    end
  end

  # Phase 5 verified both slugs against OpenRouter's live model list; the
  # newsroom reads them without allow_nil, so a regression to null has to fail
  # here rather than at publication time.
  test "the Phase 5 newsroom model slugs are filled in with verified slugs" do
    %i[writer_model brief_model].each do |key|
      slug = Pol::Params.fetch!(:newsroom, key)
      assert_kind_of String, slug
      assert_match(%r{\A[\w.-]+/[\w.:-]+\z}, slug, "#{key} should be an OpenRouter vendor/model slug")
    end
  end

  test "the newsroom's caps and bounds are all present and positive" do
    %i[max_output_tokens max_dispatches_per_race_per_day max_dispatches_per_day movement_threshold
       movement_note_cooldown_days brief_poll_count recent_headline_count headline_max_chars
       dek_max_chars body_max_words].each do |key|
      assert_operator Pol::Params.fetch!(:newsroom, key), :>, 0, "newsroom.#{key}"
    end
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
    # The simulator derives both Senate thresholds from this rather than
    # carrying 50 and 51 as literals.
    assert_equal 100, Pol::Params.fetch!(:chambers, :senate_total_seats)
    assert_equal 51, (Pol::Params.fetch!(:chambers, :senate_total_seats) / 2) + 1
  end

  test "the thresholds the engine leans on all live in the file" do
    assert_equal 2, Pol::Params.fetch!(:averaging, :min_polls_in_window)
    assert_operator Pol::Params.fetch!(:simulation, :stale_run_minutes), :>, 0
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
