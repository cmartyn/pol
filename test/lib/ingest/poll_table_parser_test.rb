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
    assert_equal 38, party_only,
                 "without a candidate list the parser can only filter on party, so the Kemp/Greene/" \
                 "Raffensperger matchups come through too — all but the one against a " \
                 "\"Generic Republican\", which is refused on the placeholder rather than the name"
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

  # Montana's page is the live example: a Libertarian column that most
  # pollsters did not test, dashed out row after row. Reading those dashes as
  # "no result" rather than "unparseable" is worth 13 real polls on that page
  # alone; reading them as zero would be inventing data.
  test "a dashed column means that candidate was not tested, not that the row is broken" do
    html = three_way_html(minor: [ "—", "3%" ])

    result = Ingest::PollTableParser.new(html: html, page_url: PAGE_URL).call

    assert_equal 2, result.rows.size
    assert_equal 0, result.skipped
    assert_equal %i[dem rep], result.rows.first.results.map(&:party)
    assert_equal %i[dem rep other], result.rows.second.results.map(&:party)
  end

  test "a dashed major-party column is a broken row, not an untested candidate" do
    result = Ingest::PollTableParser.new(html: three_way_html(minor: [ "3%" ], dem: "—"), page_url: PAGE_URL).call

    assert_empty result.rows
    assert_equal 1, result.reasons[:missing_percentage]
  end

  def three_way_html(minor:, dem: "48%")
    rows = minor.map.with_index do |value, index|
      "<tr><td>Pollster #{index}</td><td>July #{index + 1}–#{index + 3}, 2026</td><td>600 (LV)</td>" \
        "<td>#{dem}</td><td>44%</td><td>#{value}</td></tr>"
    end.join

    <<~HTML
      <html><body><section><h2 id="Polling">Polling</h2>
        <table class="wikitable"><tbody>
          <tr><th>Poll source</th><th>Date(s) administered</th><th>Sample size</th>
              <th>Alani Bankhead (D)</th><th>Kurt Alme (R)</th><th>Kyle Austin (L)</th></tr>
          #{rows}
        </tbody></table>
      </section></body></html>
    HTML
  end

  test "a table with fewer than two parties is not a general-election poll" do
    html = poll_page_html(
      dem_column: "Jordan Ellis (D)", rep_column: "Undecided",
      rows: [ { pollster: "Beacon", dates: "July 1–3, 2026", sample: "500 (LV)", dem: "48%", rep: "52%" } ]
    )

    result = Ingest::PollTableParser.new(html: html, page_url: PAGE_URL).call

    assert_empty result.rows
    assert_equal 0, result.skipped
    assert_equal({ no_party_columns: 1 }, result.refusals)
  end

  # ---------------------------------------------------------------------
  # Refusals: why a table was turned down, not just that it was
  # ---------------------------------------------------------------------

  # Real, trimmed Parsoid HTML again, this time from state House pages.
  def parse_district(fixture, default_district: nil, district_candidates: {})
    Ingest::PollTableParser.new(
      html: file_fixture(fixture).read, page_url: PAGE_URL, scope: :district,
      district_candidates: district_candidates, default_district: default_district
    ).call
  end

  test "a table refused is a table counted, with a reason" do
    result = parse("senate_georgia.html", candidates: georgia_candidates)

    assert_equal 18, result.refused
    assert_equal result.refusals.values.sum, result.refused, "the count is the total of the reasons"
    assert_equal 4, result.refusals[:aggregator_table]
    assert_equal 7, result.refusals[:no_candidate_column_match], "the hypothetical matchups"
    assert_equal 10, result.rows.size, "and the real matchup still comes through"
  end

  test "a page with no polling section says so, rather than looking like a page we could not read" do
    result = parse_district("house_delaware.html", default_district: 1)

    assert_empty result.rows
    assert_equal({ no_polling_section: 1 }, result.refusals)
    assert_equal 0, result.refused, "no table was turned down, because there was no table to turn down"
    assert_operator Nokogiri::HTML5(file_fixture("house_delaware.html").read).css("table.wikitable").size, :>, 0,
                    "the page does have tables — fundraising and ratings — and none of them is a refusal"
  end

  # One fixture per reason the parser can emit, so a reason cannot be added to
  # the list without a real page that produces it.
  test "every refusal reason the parser declares is one a real page produces" do
    observed = [
      parse("senate_georgia.html", candidates: georgia_candidates),
      parse("poll_table_malformed.html", candidates: [ candidate("Jack Reed", :dem) ]),
      parse_district("house_delaware.html", default_district: 1),
      parse_district("house_california.html"),
      parse_district("house_washington.html"),
      parse_district("house_north_carolina.html")
    ].flat_map { |result| result.refusals.keys }.uniq

    assert_equal Ingest::PollTableParser::REFUSAL_REASONS.sort, observed.sort
  end

  test "an aggregator average and a vote-results table are refused for what they are" do
    assert_equal 4, parse("senate_georgia.html", candidates: georgia_candidates).refusals[:aggregator_table]
    # California's 22nd files its primary result table inside the Polling
    # section, where a table we cannot read would also land.
    assert_equal 1, parse_district("house_california.html").refusals[:results_table]
  end

  test "a table we cannot make sense of is told apart from one we declined on purpose" do
    result = parse("poll_table_malformed.html", candidates: [ candidate("Jack Reed", :dem) ])

    assert_equal 1, result.refusals[:layout_unrecognized]
  end

  # ---------------------------------------------------------------------
  # District pages
  # ---------------------------------------------------------------------

  test "Michigan's poll rows are attributed to the district section that encloses them" do
    result = parse_district("house_michigan.html")

    assert_equal 13, result.rows.size
    assert_equal({ 4 => 3, 7 => 7, 10 => 3 }, result.rows.group_by(&:district).transform_values(&:size))
    assert_equal 4, result.refusals[:primary_only_table]
  end

  test "a district row carries the page's polling anchor and its own cells" do
    row = parse_district("house_michigan.html").rows.find { |candidate_row| candidate_row.district == 7 }

    assert_match(/\A#{Regexp.escape(PAGE_URL)}#/, row.source_url)
    assert_equal "Poll source", row.raw_payload["columns"].keys.first
    assert_equal %i[dem rep], row.results.map(&:party).sort
  end

  test "a primary field is refused even where its columns carry party tags" do
    # Washington runs a top-two primary: District 4's field is four Republicans
    # and a Democrat, all labelled, which passes every party-column test there
    # is. Two candidates of one party is what gives it away.
    result = parse_district("house_washington.html")

    assert_equal 3, result.refusals[:multiple_same_party_columns]
    assert_equal [ 3, 5 ], result.rows.map(&:district).uniq.sort
    assert_not_includes result.rows.map(&:district), 4
  end

  test "a placeholder opponent is not a matchup" do
    result = parse_district("house_alaska.html", default_district: 1)

    assert_equal 2, result.refusals[:generic_candidate_column]
    assert(result.rows.none? { |row| row.raw_payload["columns"].keys.any? { |label| label.match?(/generic/i) } })
  end

  test "a state with one at-large district needs no district heading to read" do
    result = parse_district("house_alaska.html", default_district: 1)

    assert_equal 7, result.rows.size
    assert_equal [ 1 ], result.rows.map(&:district).uniq
  end

  test "a polling table under no district at all is refused, not guessed at" do
    # North Carolina polls its congressional vote statewide. Ten real poll rows
    # sit in that table and none of them belongs to a district.
    result = parse_district("house_north_carolina.html")

    assert_equal 1, result.refusals[:district_unresolved]
    assert_equal [ 1 ], result.rows.map(&:district).uniq, "only the District 1 tables came through"
  end

  test "district candidates are matched per district, not across the page" do
    result = parse_district(
      "house_michigan.html",
      district_candidates: { 7 => [ candidate("Tom Barrett", :rep), candidate("Nobody At All", :dem) ] }
    )

    assert_equal({ 4 => 3, 10 => 3 }, result.rows.group_by(&:district).transform_values(&:size),
                 "district 7's tables name a Democrat we do not hold, so only district 7 is refused")
    assert_operator result.refusals[:no_candidate_column_match], :>=, 1
  end
end
