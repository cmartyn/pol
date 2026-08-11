require "test_helper"

class Admin::SimpleCsvTest < ActiveSupport::TestCase
  BOM = "\uFEFF".freeze

  test "parses a header row and data rows into an array of hashes" do
    rows = Admin::SimpleCsv.parse("a,b,c\n1,2,3\n4,5,6\n")

    assert_equal [ { "a" => "1", "b" => "2", "c" => "3" }, { "a" => "4", "b" => "5", "c" => "6" } ], rows
  end

  test "works with no trailing newline on the last row" do
    rows = Admin::SimpleCsv.parse("a,b\n1,2")
    assert_equal [ { "a" => "1", "b" => "2" } ], rows
  end

  test "an empty file parses to no rows" do
    assert_equal [], Admin::SimpleCsv.parse("")
  end

  test "a header-only file parses to no data rows" do
    assert_equal [], Admin::SimpleCsv.parse("a,b,c\n")
  end

  test "strips whitespace from header names but not from field values" do
    rows = Admin::SimpleCsv.parse(" a , b \n  1  ,2\n")
    assert_equal [ { "a" => "  1  ", "b" => "2" } ], rows
  end

  test "a quoted field may contain a literal comma" do
    rows = Admin::SimpleCsv.parse(%(pollster,sponsor\n"Data, for Progress",Acme\n))
    assert_equal [ { "pollster" => "Data, for Progress", "sponsor" => "Acme" } ], rows
  end

  test "a quoted field may contain a literal newline" do
    rows = Admin::SimpleCsv.parse(%(a,b\n"line one\nline two",2\n))
    assert_equal [ { "a" => "line one\nline two", "b" => "2" } ], rows
  end

  test "blank lines are skipped rather than becoming a phantom row" do
    rows = Admin::SimpleCsv.parse("a,b\n1,2\n\n3,4\n")
    assert_equal [ { "a" => "1", "b" => "2" }, { "a" => "3", "b" => "4" } ], rows
  end

  test "CRLF line endings parse the same as LF" do
    rows = Admin::SimpleCsv.parse("a,b\r\n1,2\r\n")
    assert_equal [ { "a" => "1", "b" => "2" } ], rows
  end

  test "a short row fills missing trailing columns with nil rather than raising" do
    rows = Admin::SimpleCsv.parse("a,b,c\n1,2\n")
    assert_equal [ { "a" => "1", "b" => "2", "c" => nil } ], rows
  end

  test "an empty field between commas is an empty string, not nil" do
    rows = Admin::SimpleCsv.parse("a,b,c\n1,,3\n")
    assert_equal [ { "a" => "1", "b" => "", "c" => "3" } ], rows
  end

  # A leading UTF-8 byte-order-mark (Excel's "CSV UTF-8" export prepends
  # one) must not survive into the first header's name — see SimpleCsv's
  # own comment for why a corrupted "race_slug" header is a silent data
  # hazard, not just a cosmetic one.
  test "a UTF-8 BOM (as a decoded U+FEFF character) prefixed to the file parses identically to the clean file" do
    clean = "race_slug,pollster\nsenate-fl-2026-special,Beacon\n"
    bom_prefixed = BOM + clean

    assert_equal Admin::SimpleCsv.parse(clean), Admin::SimpleCsv.parse(bom_prefixed)
  end

  test "a UTF-8 BOM (as raw undecoded bytes, e.g. straight off a file upload) is stripped the same way" do
    clean = "race_slug,pollster\nsenate-fl-2026-special,Beacon\n"
    bom_prefixed = "\xEF\xBB\xBF".b + clean.b

    assert_equal Admin::SimpleCsv.parse(clean), Admin::SimpleCsv.parse(bom_prefixed)
  end

  test "a BOM-prefixed file's first header is readable under its plain name, not a corrupted one" do
    rows = Admin::SimpleCsv.parse("#{BOM}race_slug,pollster\nsenate-fl-2026-special,Beacon\n")

    assert_equal "senate-fl-2026-special", rows.first["race_slug"]
    assert_nil rows.first["#{BOM}race_slug"]
  end

  test "only a LEADING BOM is stripped — a U+FEFF character elsewhere in the file is left alone" do
    rows = Admin::SimpleCsv.parse("a,b\n1,val#{BOM}ue\n")
    assert_equal "val#{BOM}ue", rows.first["b"]
  end
end
