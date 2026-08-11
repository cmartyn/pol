require "test_helper"

class Admin::PercentValueTest < ActiveSupport::TestCase
  test "parses a plain integer-looking string to a Float" do
    assert_equal 47.0, Admin::PercentValue.parse("47")
  end

  test "parses a decimal string to a Float" do
    assert_equal 47.5, Admin::PercentValue.parse("47.5")
  end

  test "parses a negative number to a Float (range-checking is the caller's job, not this method's)" do
    assert_equal(-5.0, Admin::PercentValue.parse("-5"))
  end

  test "a non-numeric string is returned unchanged, not coerced to 0.0" do
    assert_equal "N/A", Admin::PercentValue.parse("N/A")
  end

  test "a non-numeric result is never Numeric, so it fails is_a?(Numeric) downstream" do
    refute Admin::PercentValue.parse("N/A").is_a?(Numeric)
  end

  test "whitespace-padded numbers still parse (Kernel#Float tolerates surrounding whitespace)" do
    assert_equal 47.5, Admin::PercentValue.parse(" 47.5 ")
  end
end
