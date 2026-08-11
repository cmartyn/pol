require "test_helper"

class Ingest::DateRangeTest < ActiveSupport::TestCase
  test "a single date is a one-day range" do
    assert_equal [ Date.new(2025, 4, 16), Date.new(2025, 4, 16) ], Ingest::DateRange.parse("April 16, 2025")
  end

  test "a range inside one month" do
    assert_equal [ Date.new(2025, 2, 10), Date.new(2025, 2, 12) ], Ingest::DateRange.parse("February 10–12, 2025")
  end

  test "a range spanning two months" do
    assert_equal [ Date.new(2026, 7, 30), Date.new(2026, 8, 2) ], Ingest::DateRange.parse("July 30 – August 2, 2026")
  end

  test "a range spanning the new year" do
    assert_equal [ Date.new(2025, 12, 29), Date.new(2026, 1, 4) ],
                 Ingest::DateRange.parse("December 29, 2025 – January 4, 2026")
  end

  test "accepts hyphen and em dash as well as the en dash Wikipedia actually uses" do
    expected = [ Date.new(2026, 5, 16), Date.new(2026, 5, 17) ]

    assert_equal expected, Ingest::DateRange.parse("May 16-17, 2026")
    assert_equal expected, Ingest::DateRange.parse("May 16—17, 2026")
  end

  test "tolerates abbreviated months and stray whitespace" do
    assert_equal [ Date.new(2026, 7, 8), Date.new(2026, 7, 10) ], Ingest::DateRange.parse("  Jul 8–10,  2026 ")
  end

  test "returns nil rather than guessing at anything else" do
    [ "", "  ", "sometime last spring", "through July 1, 2026", "2026", "Smarch 4, 2026", "July 32, 2026" ].each do |text|
      assert_nil Ingest::DateRange.parse(text), "expected #{text.inspect} to be unparseable"
    end
  end

  test "returns nil when the range runs backwards" do
    assert_nil Ingest::DateRange.parse("July 10–8, 2026")
    assert_nil Ingest::DateRange.parse("August 2 – July 30, 2026")
  end
end
