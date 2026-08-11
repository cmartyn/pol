require "test_helper"

class Ingest::ScraperTest < ActiveSupport::TestCase
  MAINE = "2026 United States Senate election in Maine".freeze
  FLORIDA = "2026 United States Senate special election in Florida".freeze
  GENERIC = "2026 United States elections".freeze

  # The fixture world holds exactly two 2026 Senate races, so a sweep is three
  # sources: Maine, the Florida special, and the generic ballot.
  setup do
    @maine_rows = [
      { pollster: "Harbor Analytics", dates: "July 8–10, 2026", sample: "600 (LV)", dem: "48%", rep: "44%" },
      { pollster: "Pine Street Research", dates: "June 30 – July 2, 2026", sample: "1,004 (RV)", dem: "46%", rep: "45%" },
      { pollster: "Bad Dates Polling", dates: "sometime in June", sample: "500 (LV)", dem: "45%", rep: "45%" }
    ]
    stub_wikipedia_page(MAINE, body: poll_page_html(rows: @maine_rows))
    stub_wikipedia_page(FLORIDA, status: 404)
    stub_wikipedia_page(GENERIC, fixture: "generic_ballot.html")
  end

  def scrape
    Ingest::Scraper.new(logger: Logger.new(File::NULL)).call
  end

  test "writes one ScrapeRun per source with the counts it actually saw" do
    assert_difference "ScrapeRun.count", 3 do
      @outcomes = scrape
    end

    assert_equal [ FLORIDA, MAINE, GENERIC ], @outcomes.map(&:source)

    maine = ScrapeRun.find_by!(source: MAINE)
    assert_equal "partial", maine.status, "one row had unparseable dates"
    assert_equal 3, maine.fetched_count
    assert_equal 2, maine.new_count
    assert_equal 0, maine.duplicate_count
    assert_match(/1 row\(s\) skipped/, maine.error_message)
    assert maine.started_at.present? && maine.finished_at.present?
  end

  test "ingests the polls it parsed, with provenance" do
    assert_difference "Poll.count", 92 do
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
    assert_equal 3, outcomes.size, "the other two sources still ran"
  end

  test "a source that fails outright is recorded as failed and does not stop the sweep" do
    remove_request_stub(stub_wikipedia_page(MAINE, body: poll_page_html(rows: @maine_rows)))
    stub_wikipedia_page(MAINE, status: 500)

    outcomes = scrape

    assert_equal "failed", ScrapeRun.find_by!(source: MAINE).status
    assert_match(/FetchFailed/, ScrapeRun.find_by!(source: MAINE).error_message)
    assert_equal 90, outcomes.last.created, "the generic ballot still landed"
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
      assert_difference "Poll.count", 92 do
        scrape
      end

      assert_equal Poll.order(:id).last(92).map(&:id), calls.sole.sole
    end
  end

  test "the seam is left alone when a sweep lands nothing new" do
    scrape

    recording(Ingest, :after_new_polls!) do |calls|
      scrape
      assert_empty calls
    end
  end
end
