require "test_helper"

class Ingest::PresidentialResultsParserTest < ActiveSupport::TestCase
  def margins(year)
    Ingest::PresidentialResultsParser.new(html: file_fixture("presidential_#{year}.html").read).call
  end

  test "reads a statewide D-minus-R margin for all 50 states in 2024" do
    result = margins(2024)

    assert_equal 50, result.size
    assert_in_delta(-30.47, result.fetch("AL"))
    assert_in_delta 20.14, result.fetch("CA")
    assert_in_delta(-2.19, result.fetch("GA"))
  end

  test "reads 2020 as well, where the same table shape holds" do
    result = margins(2020)

    assert_in_delta(-25.46, result.fetch("AL"))
    assert_in_delta 0.23, result.fetch("GA")
    assert_in_delta 29.16, result.fetch("CA")
  end

  test "the split-vote states are read from their statewide row, dagger and all" do
    result = margins(2024)

    assert_in_delta 6.94, result.fetch("ME")
    assert_in_delta(-20.46, result.fetch("NE"))
  end

  test "congressional-district and total rows are not mistaken for states" do
    result = margins(2024)

    assert_equal result.keys, result.keys.grep(/\A[A-Z]{2}\z/)
    assert_not result.key?("Total")
  end

  test "an unrecognisable page yields nothing rather than blowing up" do
    assert_empty Ingest::PresidentialResultsParser.new(html: "<html><body><p>nope</p></body></html>").call
  end
end
