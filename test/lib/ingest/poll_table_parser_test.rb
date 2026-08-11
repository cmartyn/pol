require "test_helper"

class Ingest::PollTableParserTest < ActiveSupport::TestCase
  PAGE_URL = "https://en.wikipedia.org/wiki/Test_page".freeze

  # Real, trimmed Parsoid HTML saved by `bin/rails pol:refresh_fixtures`.
  # Georgia is the heavy case (an aggregator table, five primary tables and
  # eight hypothetical matchups alongside the real one), Ohio is a special
  # election, Iowa is middling and Rhode Island is sparse.
  def parse(fixture, candidates: [])
    Ingest::PollTableParser.new(
      html: file_fixture(fixture).read, page_url: PAGE_URL, candidates: candidates
    ).call
  end

  def candidate(name, party)
    Candidate.new(name: name, party: party)
  end

  def georgia_candidates
    [ candidate("Jon Ossoff", :dem), candidate("Mike Collins", :rep) ]
  end

  test "Georgia yields only the Ossoff-Collins matchup" do
    result = parse("senate_georgia.html", candidates: georgia_candidates)

    assert_equal 10, result.rows.size
    assert_equal 0, result.skipped
    assert(result.rows.all? { |row| row.results.map(&:party).sort == %i[dem rep] })
  end

  test "Georgia's first row reads exactly as the page shows it" do
    row = parse("senate_georgia.html", candidates: georgia_candidates).rows.first

    assert_equal "Fabrizio Ward/ Impact Research", row.pollster
    assert_equal Date.new(2026, 7, 13), row.field_start
    assert_equal Date.new(2026, 7, 16), row.field_end
    assert_equal 1060, row.sample_size
    assert_equal :lv, row.population
    assert_equal 52.0, row.results.find { |entry| entry.party == :dem }.pct
    assert_equal 43.0, row.results.find { |entry| entry.party == :rep }.pct
  end

  test "result columns are linked to the candidate they name" do
    row = parse("senate_georgia.html", candidates: georgia_candidates).rows.first

    assert_equal "Jon Ossoff", row.results.find { |entry| entry.party == :dem }.candidate.name
    assert_equal "Mike Collins", row.results.find { |entry| entry.party == :rep }.candidate.name
  end

  test "hypothetical matchups against non-candidates are what the candidate list rejects" do
    with_candidates = parse("senate_georgia.html", candidates: georgia_candidates).rows.size
    party_only = parse("senate_georgia.html").rows.size

    assert_equal 10, with_candidates
    assert_equal 39, party_only,
                 "without a candidate list the parser can only filter on party, so the Kemp/Greene/" \
                 "Raffensperger matchups come through too"
  end

  test "aggregator averages and primary polls never become polls" do
    # Georgia's polling sections hold six tables the parser must refuse: one
    # "Source of poll aggregation" average and five Republican-primary tables
    # whose columns carry no party at all. Both would show up as extra rows.
    tables = Nokogiri::HTML5(file_fixture("senate_georgia.html").read).css("table.wikitable").size
    result = parse("senate_georgia.html", candidates: georgia_candidates)

    assert_operator tables, :>, 10, "fixture should still contain the tables we are refusing"
    assert_equal 10, result.rows.size
    assert_equal 0, result.skipped, "refusing a whole table is not the same as skipping rows"
  end

  test "the Ohio special election parses, party columns in either order" do
    result = parse("senate_ohio_special.html",
                   candidates: [ candidate("Jon Husted", :rep), candidate("Sherrod Brown", :dem) ])
    row = result.rows.first

    assert_equal 15, result.rows.size
    assert_equal "New York Times/Siena University", row.pollster
    assert_equal Date.new(2026, 6, 15)..Date.new(2026, 6, 28), (row.field_start..row.field_end)
    assert_equal 601, row.sample_size
    assert_equal 50.0, row.results.find { |entry| entry.party == :rep }.pct
    assert_equal 47.0, row.results.find { |entry| entry.party == :dem }.pct
  end

  test "a middling race and a sparse one both parse" do
    iowa = parse("senate_iowa.html", candidates: [ candidate("Ashley Hinson", :rep), candidate("Josh Turek", :dem) ])
    rhode_island = parse("senate_rhode_island.html",
                         candidates: [ candidate("Jack Reed", :dem), candidate("Raymond McKay", :rep) ])

    assert_equal 9, iowa.rows.size
    assert_equal "Emerson College", iowa.rows.first.pollster
    assert_equal 2, rhode_island.rows.size
    assert_equal "University of New Hampshire", rhode_island.rows.first.pollster
  end

  test "the generic ballot parses on party columns alone" do
    result = parse("generic_ballot.html")
    row = result.rows.first

    assert_equal 90, result.rows.size
    assert_equal "Quantus Insights", row.pollster
    assert_equal 49.0, row.results.find { |entry| entry.party == :dem }.pct
    assert_equal 43.0, row.results.find { |entry| entry.party == :rep }.pct
    assert_nil row.results.first.candidate
  end

  test "a pollster cell spanning several rows is repeated onto each of them" do
    rows = parse("generic_ballot.html").rows[1, 2]

    assert_equal [ "The Economist/YouGov", "The Economist/YouGov" ], rows.map(&:pollster)
    assert_equal [ Date.new(2026, 7, 31), Date.new(2026, 7, 31) ], rows.map(&:field_start)
    assert_equal [ 1472, 1607 ], rows.map(&:sample_size), "the two rows differ only by subsample"
    assert_equal %i[rv a], rows.map(&:population)
  end

  test "a partisan tag on a pollster is dropped so the two spellings canonicalise together" do
    ohio = parse("senate_ohio_special.html",
                 candidates: [ candidate("Jon Husted", :rep), candidate("Sherrod Brown", :dem) ])

    assert_includes ohio.rows.map(&:pollster), "Tulchin Research"
    assert_not_includes ohio.rows.map(&:pollster), "Tulchin Research (D)"
  end

  test "each row carries the page URL plus its section anchor, and its cells" do
    row = parse("senate_rhode_island.html",
                candidates: [ candidate("Jack Reed", :dem), candidate("Raymond McKay", :rep) ]).rows.first

    assert_match(/\A#{Regexp.escape(PAGE_URL)}#Polling/, row.source_url)
    assert_equal "University of New Hampshire", row.raw_payload.dig("columns", "Poll source")
    assert_equal "664 (LV)", row.raw_payload.dig("columns", "Sample size")
    assert_equal 0, row.raw_payload["row_index"]
  end

  test "a mangled table produces skips with reasons, never an exception" do
    result = parse("poll_table_malformed.html",
                   candidates: [ candidate("Jack Reed", :dem), candidate("Raymond McKay", :rep) ])

    assert_equal 2, result.rows.size, "the two intact rows still come through"
    assert_equal 4, result.skipped
    assert_equal 6, result.fetched
    assert_equal 1, result.reasons[:unparseable_dates]
    assert_equal 1, result.reasons[:missing_pollster]
    assert_equal 2, result.reasons[:missing_percentage]
  end

  test "a table with fewer than two parties is not a general-election poll" do
    html = poll_page_html(
      dem_column: "Jordan Ellis (D)", rep_column: "Undecided",
      rows: [ { pollster: "Beacon", dates: "July 1–3, 2026", sample: "500 (LV)", dem: "48%", rep: "52%" } ]
    )

    result = Ingest::PollTableParser.new(html: html, page_url: PAGE_URL).call

    assert_empty result.rows
    assert_equal 0, result.skipped
  end
end
