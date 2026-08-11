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

  test "fetch! raises KeyError on a nil value by default" do
    assert_raises(KeyError) { Pol::Params.fetch!(:fundamentals, :pres_national_margin_2024) }
  end

  test "fetch! returns nil when allow_nil is true" do
    assert_nil Pol::Params.fetch!(:fundamentals, :pres_national_margin_2024, allow_nil: true)
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
