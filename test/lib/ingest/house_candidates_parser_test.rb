require "test_helper"

class Ingest::HouseCandidatesParserTest < ActiveSupport::TestCase
  PAGE_URL = "https://en.wikipedia.org/wiki/Test_page".freeze

  # Real, trimmed Parsoid HTML saved by `bin/rails pol:refresh_fixtures`.
  # Between them the four state pages cover every shape the parser reads:
  # Minnesota is settled and multi-district, Massachusetts votes in September
  # and so is entirely unsettled, Alaska is a single at-large seat, and
  # California's top-two primary sends two Democrats to one general.
  def parse(fixture)
    parser = Ingest::HouseCandidatesParser.new(html: file_fixture(fixture).read, page_url: PAGE_URL)
    [ parser.call, parser.warnings ]
  end

  def entry(name, party, incumbent: false)
    { "name" => name, "party" => party, "incumbent" => incumbent }
  end

  # ---------------------------------------------------------------------
  # A settled multi-district state
  # ---------------------------------------------------------------------

  test "Minnesota's settled districts come out as candidate entries" do
    districts, warnings = parse("house_minnesota.html")

    assert_equal [ 1, 2 ], districts.keys.sort
    assert_empty warnings
    assert_equal [ entry("Brad Finstad", "rep", incumbent: true), entry("Jake Johnson", "dem") ],
                 districts.fetch(1)
  end

  # Minnesota's Democrats appear on the ballot — and in every one of these
  # infoboxes — as "Democratic (DFL)". The 2024 results parser once read that
  # label as no Democrat at all and cost eight districts their baselines, which
  # is why the fixture is Minnesota rather than a state that just says
  # "Democratic".
  test "Minnesota's DFL label reads as Democratic" do
    districts, = parse("house_minnesota.html")

    assert_equal "dem", districts.fetch(2).find { |candidate| candidate["name"] == "Matt Little" }["party"]
    assert_equal "dem", districts.fetch(1).find { |candidate| candidate["name"] == "Jake Johnson" }["party"]
  end

  # Minnesota's 2nd is an open seat: Angie Craig holds it and is not on the
  # ballot, so neither nominee is an incumbent. The 1st is the ordinary case,
  # where the incumbent is running and the challenger is not one.
  test "the incumbent flag follows the district's own incumbent line" do
    districts, = parse("house_minnesota.html")

    assert_equal [ true, false ], districts.fetch(1).map { |candidate| candidate["incumbent"] }
    assert_equal [ false, false ], districts.fetch(2).map { |candidate| candidate["incumbent"] },
                 "the 2nd's incumbent is not running, so nobody in it is an incumbent"
  end

  # ---------------------------------------------------------------------
  # Unsettled districts
  # ---------------------------------------------------------------------

  test "a state that has not held its primary yields nothing at all" do
    districts, warnings = parse("house_massachusetts.html")

    assert_empty districts
    assert_empty warnings, "an unsettled field is the normal state of a page before its primary, not a problem"
  end

  test "the Massachusetts fixture really does name candidates the parser refused" do
    text = file_fixture("house_massachusetts.html").read

    assert_includes text, "Nadia Milleron", "a named independent, opposite a nominee still marked TBD"
    assert_includes text, "(presumptive)", "and a district whose two nominees are both presumptive"
  end

  # ---------------------------------------------------------------------
  # At-large states
  # ---------------------------------------------------------------------

  # Alaska's page has no "District N" heading to read, because there is only
  # the one district to mean — the same convention Ingest::HouseResultsParser
  # follows when it numbers an at-large seat 1. Its infobox also heads the row
  # "Candidate" rather than "Nominee", because a ranked-choice field has no
  # party nominees.
  test "an at-large state's single district is numbered 1" do
    districts, warnings = parse("house_alaska.html")

    assert_equal [ 1 ], districts.keys
    assert_empty warnings
    assert_equal [ entry("Nick Begich III", "rep", incumbent: true), entry("Bill Hill", "ind") ],
                 districts.fetch(1)
  end

  # ---------------------------------------------------------------------
  # Top-two states
  # ---------------------------------------------------------------------

  # California's 11th is a genuine top-two general between two Democrats. There
  # is no two-party matchup in it, and seeding two Democrats would leave the
  # race looking as though its Republican had gone missing, so the district is
  # dropped whole — but loudly, because a same-party general is a real fact
  # about the seat and not a parse failure.
  test "a same-party general is skipped with a warning, and its neighbours are not" do
    districts, warnings = parse("house_california.html")

    assert_equal [ 22, 48 ], districts.keys.sort
    assert_equal [ "#{PAGE_URL} district 11: two dem candidates in the general " \
                   "(\"Connie Chan\", \"Scott Wiener\"); district skipped" ], warnings
  end

  test "California's two-party districts read straight through" do
    districts, = parse("house_california.html")

    assert_equal [ entry("David Valadao", "rep", incumbent: true), entry("Randy Villegas", "dem") ],
                 districts.fetch(22)
    assert_equal [ entry("Jim Desmond", "rep"), entry("Marni von Wilpert", "dem") ],
                 districts.fetch(48), "the 48th is open — Darrell Issa holds it and is not running"
  end

  test "a state page's polling tables are not candidate lists" do
    districts, = parse("house_california.html")

    assert_equal 2, districts.size,
                 "the fixture carries four polling tables and a primary results table; none of them is a field"
  end

  # ---------------------------------------------------------------------
  # Uncontested races, and names spelled two ways
  # ---------------------------------------------------------------------

  # A field of one is normally indistinguishable from an infobox somebody only
  # half filled in, so it is not read as a field at all. Florida's 10th is the
  # exception the page makes for itself: it says "(Uncontested)" in the cell,
  # which is a statement about the ballot rather than a gap in the box.
  test "an uncontested race is a settled field of one" do
    districts, warnings = parse("house_florida.html")

    assert_equal [ entry("Maxwell Frost", "dem", incumbent: true) ], districts.fetch(10)
    assert_empty warnings
  end

  # Florida's 26th runs "Mario Díaz-Balart" against an incumbent line that
  # spells him "Mario Diaz-Balart". Comparing the two as written makes the
  # sitting member of twenty years read as a challenger.
  test "an incumbent whose accents are dropped in one place is still the incumbent" do
    districts, = parse("house_florida.html")

    assert_equal entry("Mario Díaz-Balart", "rep", incumbent: true), districts.fetch(26).first
    assert_equal entry("Jared Moskowitz", "dem"), districts.fetch(25).first,
                 "the 25th's incumbent line names Debbie Wasserman Schultz, so its nominee is not one"
  end

  # ---------------------------------------------------------------------
  # Infoboxes we cannot read
  # ---------------------------------------------------------------------

  # Hand-edited from the Minnesota fixture, and not refreshed by
  # pol:refresh_fixtures: its 1st district's Party row was filled in for one
  # nominee only, and its 2nd district's infobox has no Party row at all.
  test "a candidate whose party we cannot read is dropped, and the rest of the district kept" do
    districts, warnings = parse("house_candidates_malformed.html")

    assert_equal [ entry("Brad Finstad", "rep", incumbent: true) ], districts.fetch(1)
    assert_includes warnings, "#{PAGE_URL} district 1: unreadable party \"\" for \"Jake Johnson\"; candidate skipped"
  end

  test "an infobox that does not say who is of what party is refused whole" do
    districts, warnings = parse("house_candidates_malformed.html")

    assert_not districts.key?(2)
    assert_includes warnings, "#{PAGE_URL} district 2: infobox has no party row; district skipped"
  end
end
