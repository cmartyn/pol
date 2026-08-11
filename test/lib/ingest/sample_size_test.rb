require "test_helper"

class Ingest::SampleSizeTest < ActiveSupport::TestCase
  test "reads the size and the population code" do
    assert_equal [ 600, :lv ], Ingest::SampleSize.parse("600 (LV)")
    assert_equal [ 1048, :lv ], Ingest::SampleSize.parse("1,048 (LV)")
    assert_equal [ 24000, :rv ], Ingest::SampleSize.parse("24,000 (RV)")
    assert_equal [ 1262, :a ], Ingest::SampleSize.parse("1,262 (A)")
  end

  test "an unrecognised population code leaves the population unknown but keeps the size" do
    assert_equal [ 900, :unknown ], Ingest::SampleSize.parse("900 (V)")
    assert_equal [ 900, :unknown ], Ingest::SampleSize.parse("900")
  end

  test "a missing or dashed cell yields no size at all" do
    [ "", "  ", "–", "—", "n/a" ].each do |text|
      assert_equal [ nil, :unknown ], Ingest::SampleSize.parse(text), "expected #{text.inspect} to yield no size"
    end
  end
end
