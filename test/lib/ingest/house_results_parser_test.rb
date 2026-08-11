require "test_helper"

class Ingest::HouseResultsParserTest < ActiveSupport::TestCase
  # The fixture keeps four states off the real 2024 results page, chosen for
  # what they break: Alabama (a rowspan district and safe-seat blowouts),
  # Alaska (ranked choice), Louisiana (a jungle primary with several
  # Republicans on one line) and Washington (top-two, including a race with no
  # Republican at all).
  SOURCE = "https://en.wikipedia.org/wiki/2024_United_States_House_of_Representatives_elections".freeze

  setup do
    @districts = Ingest::HouseResultsParser.new(html: file_fixture("house_results_2024.html").read, page_url: SOURCE).call
  end

  test "reads every district in the fixture's states, and no delegates or specials" do
    assert_equal 24, @districts.size
    assert_equal({ "AL" => 7, "AK" => 1, "LA" => 6, "WA" => 10 }, @districts.values.group_by(&:state).transform_values(&:size))
    assert_not @districts.key?("NY-3"), "the Special elections table must not become a district"
  end

  test "a straightforward two-way race" do
    district = @districts.fetch("AL-1")

    assert_equal 21.5, district.dem_pct
    assert_equal 78.5, district.rep_pct
    assert_in_delta(-57.0, district.margin)
    assert district.contested?
    assert_equal SOURCE, district.source_url
  end

  test "an at-large district is district 1" do
    assert_equal 1, @districts.fetch("AK-1").number
  end

  test "several candidates of one party are summed, not overwritten" do
    district = @districts.fetch("LA-1")

    assert_equal 24.0, district.dem_pct
    assert_equal 74.1, district.rep_pct, "Scalise's 66.8% plus the other Republican on the ballot"
  end

  test "ranked choice counts the deciding round only, never both" do
    district = @districts.fetch("AK-1")

    assert_equal 48.8, district.dem_pct
    assert_equal 51.2, district.rep_pct
    assert_in_delta 100.0, district.dem_pct + district.rep_pct,
                    0.5, "summing the first round as well would put the two-party total near 200"
  end

  test "a district with no Republican on the ballot is not contested and leads Democratic" do
    district = @districts.fetch("WA-9")

    assert_equal 0.0, district.rep_pct
    assert_not district.contested?
    assert_equal :dem, district.leader
  end

  test "an unopposed Republican is not contested and leads Republican" do
    district = @districts.fetch("AL-3")

    assert_equal 100.0, district.rep_pct
    assert_equal 0.0, district.dem_pct
    assert_not district.contested?
    assert_equal :rep, district.leader
  end

  test "slugs are zero-padded so districts sort in numeric order" do
    assert_equal "house-2026-al-01", @districts.fetch("AL-1").slug
    assert_equal "house-2026-wa-10", @districts.fetch("WA-10").slug
  end
end
