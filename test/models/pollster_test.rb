require "test_helper"

class PollsterTest < ActiveSupport::TestCase
  test "canonicalize lowercases and dasherizes" do
    assert_equal "data-for-progress", Pollster.canonicalize("Data For Progress")
  end

  test "canonicalize collapses punctuation and whitespace into single dashes" do
    assert_equal "data-for-progress", Pollster.canonicalize("  Data, For...  Progress!! ")
  end

  test "canonicalize strips leading and trailing dashes" do
    assert_equal "atlasintel", Pollster.canonicalize("***AtlasIntel***")
  end
end
