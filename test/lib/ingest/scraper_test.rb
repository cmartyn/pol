require "test_helper"

class Ingest::ScraperTest < ActiveSupport::TestCase
  MAINE = "2026 United States Senate election in Maine".freeze
  FLORIDA = "2026 United States Senate special election in Florida".freeze
  GENERIC = "2026 United States elections".freeze
  MICHIGAN = "2026 United States House of Representatives elections in Michigan".freeze
  # The fixture world holds one New York district, so as far as the sweep can
  # tell New York is a single-district state and takes the singular title.
  NEW_YORK = "2026 United States House of Representatives election in New York".freeze

  # The fixture world holds two 2026 Senate races and one New York district;
  # setup adds three Michigan districts. A sweep is therefore five sources:
  # the two Senate pages, the generic ballot, and the two state House pages.
  setup do
    @maine_rows = [
      { pollster: "Harbor Analytics", dates: "July 8–10, 2026", sample: "600 (LV)", dem: "48%", rep: "44%" },
      { pollster: "Pine Street Research", dates: "June 30 – July 2, 2026", sample: "1,004 (RV)", dem: "46%", rep: "45%" },
      { pollster: "Bad Dates Polling", dates: "sometime in June", sample: "500 (LV)", dem: "45%", rep: "45%" }
    ]
    stub_wikipedia_page(MAINE, body: poll_page_html(rows: @maine_rows))
    stub_wikipedia_page(FLORIDA, status: 404)
    stub_wikipedia_page(GENERIC, fixture: "generic_ballot.html")
    michigan_districts
    stub_wikipedia_page(MICHIGAN, fixture: "house_michigan.html")
    stub_wikipedia_page(NEW_YORK, fixture: "house_delaware.html")
  end

  # The three districts the Michigan fixture carries polls for.
  def michigan_districts(numbers = [ 4, 7, 10 ])
    numbers.map do |number|
      Race.create!(office: :house, state: "MI", district: number, cycle: 2026,
                   slug: "house-2026-mi-#{number.to_s.rjust(2, '0')}", baseline_margin: 0.0)
    end
  end

  def scrape
    Ingest::Scraper.new(logger: Logger.new(File::NULL)).call
  end

  test "writes one ScrapeRun per source with the counts it actually saw" do
    assert_difference "ScrapeRun.count", 5 do
      @outcomes = scrape
    end

    assert_equal [ FLORIDA, MAINE, GENERIC, MICHIGAN, NEW_YORK ], @outcomes.map(&:source)

    maine = ScrapeRun.find_by!(source: MAINE)
    assert_equal "partial", maine.status, "one row had unparseable dates"
    assert_equal 3, maine.fetched_count
    assert_equal 2, maine.new_count
    assert_equal 0, maine.duplicate_count
    assert_match(/1 row\(s\) skipped/, maine.error_message)
    assert maine.started_at.present? && maine.finished_at.present?
  end

  test "ingests the polls it parsed, with provenance" do
    assert_difference "Poll.count", 105 do
      scrape
    end

    poll = Poll.joins(:pollster).find_by!(pollsters: { slug: "harbor-analytics" })
    assert_equal races(:senate_maine), poll.race
    assert_equal Date.new(2026, 7, 8), poll.field_start
    assert_equal 600, poll.sample_size
    assert_equal "lv", poll.population
    assert_equal "scraped", poll.entry_mode
    assert_equal [ 44.0, 48.0 ], poll.poll_results.order(:pct).map(&:pct)
    assert_equal candidates(:maine_dem), poll.poll_results.find_by(party: :dem).candidate
    assert_match(%r{\Ahttps://en\.wikipedia\.org/wiki/2026_United_States_Senate_election_in_Maine#}, poll.source_url)
  end

  test "generic-ballot polls are recorded against no race at all" do
    assert_difference "Poll.for_generic_ballot.count", 90 do
      scrape
    end

    run = ScrapeRun.find_by!(source: GENERIC)
    assert_equal "succeeded", run.status
    assert_equal 90, run.new_count
    assert_nil Poll.joins(:pollster).find_by!(pollsters: { slug: "quantus-insights" }).race_id
  end

  test "a missing page is a partial run, not a crash, and the sweep carries on" do
    outcomes = scrape
    florida = ScrapeRun.find_by!(source: FLORIDA)

    assert_equal "partial", florida.status
    assert_match(/page not available/, florida.error_message)
    assert_equal 0, florida.fetched_count
    assert_equal 5, outcomes.size, "the other four sources still ran"
  end

  test "a source that fails outright is recorded as failed and does not stop the sweep" do
    remove_request_stub(stub_wikipedia_page(MAINE, body: poll_page_html(rows: @maine_rows)))
    stub_wikipedia_page(MAINE, status: 500)

    outcomes = scrape

    assert_equal "failed", ScrapeRun.find_by!(source: MAINE).status
    assert_match(/FetchFailed/, ScrapeRun.find_by!(source: MAINE).error_message)
    assert_equal 90, outcomes.find { |outcome| outcome.source == GENERIC }.created,
                 "the generic ballot still landed"
  end

  test "a second sweep finds everything already there" do
    scrape

    assert_no_difference "Poll.count" do
      @outcomes = scrape
    end

    maine = ScrapeRun.where(source: MAINE).order(:id).last
    assert_equal 2, maine.duplicate_count
    assert_equal 0, maine.new_count
  end

  # The ids rather than the count: downstream of the run, the newsroom writes
  # about the polls this sweep created, and nothing else can tell which ones
  # those were.
  test "the model-run seam is called once with the ids of the polls the sweep created" do
    recording(Ingest, :after_new_polls!) do |calls|
      assert_difference "Poll.count", 105 do
        scrape
      end

      assert_equal Poll.order(:id).last(105).map(&:id), calls.sole.sole
    end
  end

  test "the seam is left alone when a sweep lands nothing new" do
    scrape

    recording(Ingest, :after_new_polls!) do |calls|
      scrape
      assert_empty calls
    end
  end

  # ---------------------------------------------------------------------
  # District sources
  # ---------------------------------------------------------------------

  test "a state House page becomes district polls against the right races" do
    scrape

    michigan = ScrapeRun.find_by!(source: MICHIGAN)
    assert_equal 13, michigan.fetched_count
    assert_equal 13, michigan.new_count

    by_district = Race.house.where(state: "MI").to_h { |race| [ race.district, race.polls.count ] }
    assert_equal({ 4 => 3, 7 => 7, 10 => 3 }, by_district)

    poll = Race.house.find_by!(state: "MI", district: 7).polls.first
    assert_equal "scraped", poll.entry_mode
    assert_match(%r{\Ahttps://en\.wikipedia\.org/wiki/2026_United_States_House_of_Representatives_elections_in_Michigan#},
                 poll.source_url)
    assert_equal %w[dem rep], poll.poll_results.map(&:party).sort
  end

  test "each district poll records which contest it measured" do
    scrape

    keys = Race.house.find_by!(state: "MI", district: 10).polls.pluck(:matchup_key)
    assert_equal [ "dem:chung|rep:bouchard", "dem:greimel|rep:bouchard", "dem:hines|rep:bouchard" ], keys.sort
    assert_equal [ "dem:mccann|rep:huizenga" ],
                 Race.house.find_by!(state: "MI", district: 4).polls.pluck(:matchup_key).uniq
    assert(Poll.for_generic_ballot.all? { |poll| poll.matchup_key.nil? },
           "the generic ballot's columns name nobody")
  end

  test "a row whose district we hold no race for is skipped and counted, never reassigned" do
    Race.house.find_by!(state: "MI", district: 10).destroy!

    assert_difference "Poll.count", 102, "the three District 10 rows are the ones missing" do
      scrape
    end

    michigan = ScrapeRun.find_by!(source: MICHIGAN)
    assert_equal 13, michigan.fetched_count
    assert_equal 10, michigan.new_count
    assert_equal "partial", michigan.status
    assert_match(/3 row\(s\) skipped/, michigan.error_message)
    assert_equal 3, Race.house.find_by!(state: "MI", district: 4).polls.count, "and nothing was reassigned"
  end

  test "a state page is skipped entirely when we hold no districts for it" do
    Race.house.where(state: "MI").destroy_all

    outcomes = scrape

    assert_not_includes outcomes.map(&:source), MICHIGAN
  end

  test "scrape.max_district_sources caps how many state pages a sweep reads" do
    with_params(scrape: { max_district_sources: 0 }) do
      outcomes = scrape

      assert_equal [ FLORIDA, MAINE, GENERIC ], outcomes.map(&:source)
    end
  end

  # ---------------------------------------------------------------------
  # Refusal accounting
  # ---------------------------------------------------------------------

  test "refusal counts and reasons survive the trip from parser to row" do
    scrape

    michigan = ScrapeRun.find_by!(source: MICHIGAN)
    assert_equal 5, michigan.refused_count
    assert_equal({ "primary_only_table" => 4, "generic_candidate_column" => 1 }, michigan.refusal_reasons)
    assert_equal michigan.refused_count, michigan.refusal_reasons.values.sum
  end

  test "a source that refused tables but still read polls is a clean sweep" do
    scrape

    michigan = ScrapeRun.find_by!(source: MICHIGAN)
    assert_equal "succeeded", michigan.status,
                 "refusing a primary field is routine; it is refusing everything that matters"
    assert_nil michigan.error_message
    assert michigan.refused_tables?
    assert_not michigan.refusal_alarm?
  end

  test "a page with no polling section is succeeded, with the reason said out loud" do
    scrape

    new_york = ScrapeRun.find_by!(source: NEW_YORK)
    assert_equal "succeeded", new_york.status
    assert_equal 0, new_york.fetched_count
    assert_equal 0, new_york.refused_count
    assert_equal({ "no_polling_section" => 1 }, new_york.refusal_reasons)
    assert new_york.no_polling_section?
    assert_not new_york.refused_tables?
  end

  test "a source that refused every table and read nothing is partial, not a quiet success" do
    remove_request_stub(stub_wikipedia_page(NEW_YORK, fixture: "house_delaware.html"))
    # Nothing but a primary field: the shape of a district going dark.
    stub_wikipedia_page(NEW_YORK, body: primary_only_page)

    scrape

    new_york = ScrapeRun.find_by!(source: NEW_YORK)
    assert_equal "partial", new_york.status
    assert_equal 0, new_york.fetched_count
    assert_equal 1, new_york.refused_count
    assert_equal({ "primary_only_table" => 1 }, new_york.refusal_reasons)
    assert_match(/no polls read; refused primary_only_table ×1/, new_york.error_message)
    assert new_york.dark?
  end

  test "a polling table we cannot read at all is partial even when the page yields polls" do
    remove_request_stub(stub_wikipedia_page(MAINE, body: poll_page_html(rows: @maine_rows)))
    stub_wikipedia_page(MAINE, body: poll_page_html(rows: @maine_rows) + unreadable_table)

    scrape

    maine = ScrapeRun.find_by!(source: MAINE)
    assert_equal "partial", maine.status
    assert_equal 2, maine.new_count, "the good table still came through"
    assert_equal({ "layout_unrecognized" => 1 }, maine.refusal_reasons)
    assert_match(/1 table\(s\) not recognised \(layout_unrecognized ×1\)/, maine.error_message)
    assert maine.refusal_alarm?
  end

  def primary_only_page
    <<~HTML
      <html><body><section><h2 id="Primary">Democratic primary</h2>
        <section><h3 id="Polling">Polling</h3>
          <table class="wikitable"><tbody>
            <tr><th>Poll source</th><th>Date(s) administered</th><th>Sample size</th>
                <th>Avery Lane</th><th>Robin Pike</th></tr>
            <tr><td>Beacon Research</td><td>July 1–3, 2026</td><td>500 (LV)</td><td>48%</td><td>44%</td></tr>
          </tbody></table>
        </section>
      </section></body></html>
    HTML
  end

  # A table under a Polling heading with no header row at all: the shape of a
  # page that has been restructured under us.
  def unreadable_table
    <<~HTML
      <section><h2 id="Polling-2">Polling</h2>
        <table class="wikitable"><tbody>
          <tr><td>Beacon Research</td><td>July 1–3, 2026</td><td>48%</td></tr>
        </tbody></table>
      </section>
    HTML
  end
end
