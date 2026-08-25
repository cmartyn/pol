require "test_helper"

class Ingest::SyncHouseCandidatesJobTest < ActiveJob::TestCase
  # The fixture world holds one House race (house_ny_17, NY-17), so New York
  # is a source in every run of this job regardless of what a test is about —
  # same reasoning as Ingest::ScraperTest's NEW_YORK constant. Stubbed empty
  # by default; a test that wants to say something about NY overrides it.
  NY = "2026 United States House of Representatives election in New York".freeze
  NH = "2026 United States House of Representatives elections in New Hampshire".freeze
  # The title Sources.district_title picks when only one NH race is held —
  # a state with a single race takes the singular title, same as Alaska.
  NH_SINGLE = "2026 United States House of Representatives election in New Hampshire".freeze
  ALASKA = "2026 United States House of Representatives election in Alaska".freeze

  setup do
    stub_wikipedia_page(NY, body: "<html><body></body></html>")
  end

  def nh_races(numbers = [ 1, 2 ])
    numbers.map do |number|
      Race.create!(office: :house, state: "NH", district: number, cycle: 2026,
                   slug: "house-2026-nh-#{number.to_s.rjust(2, '0')}", baseline_margin: 0.0)
    end
  end

  # ---------------------------------------------------------------------
  # Cron
  # ---------------------------------------------------------------------

  test "the cron schedule runs this job at 05:00 Eastern" do
    entry = Rails.application.config.good_job.cron.fetch(:pol_house_candidates)

    assert_equal "Ingest::SyncHouseCandidatesJob", entry[:class]
    assert_equal "0 5 * * * America/New_York", entry[:cron]
    assert entry[:description].present?
  end

  # The sixth field is fugit's timezone; asserting the parsed schedule stays
  # 05:00 Eastern across a DST boundary is what proves it is really being
  # read, rather than 05:00 UTC or 05:00 wherever the server's clock is.
  test "the parsed schedule is Eastern all year, not the server's clock" do
    schedule = Fugit.parse_cron(Rails.application.config.good_job.cron.fetch(:pol_house_candidates)[:cron])

    assert_equal "America/New_York", schedule.zone
    summer = schedule.next_time(Time.utc(2026, 7, 1)).to_utc_time
    winter = schedule.next_time(Time.utc(2026, 12, 1)).to_utc_time
    assert_equal 9, summer.hour, "05:00 EDT is 09:00 UTC"
    assert_equal 10, winter.hour, "05:00 EST is 10:00 UTC"
  end

  test "the job is enqueueable on the default queue" do
    assert_enqueued_with(job: Ingest::SyncHouseCandidatesJob, queue: "default") do
      Ingest::SyncHouseCandidatesJob.perform_later
    end
  end

  # ---------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------

  test "seeds candidates for every settled district, one ScrapeRun per state page" do
    nh_races
    stub_wikipedia_page(NH, body: house_candidates_page_html(districts: [
      { number: 1, nominees: [ [ "Jordan Ellis", "Democratic" ], [ "Pat Rivers", "Republican" ] ], incumbent: "Pat Rivers" },
      { number: 2, nominees: [ [ "Alex Chen", "Democratic" ], [ "Sam Torres", "Republican" ] ] }
    ]))

    assert_difference "ScrapeRun.count", 2, "one row for New Hampshire, one for the New York fixture race" do
      Ingest::SyncHouseCandidatesJob.perform_now
    end

    nh1 = Race.house.find_by!(state: "NH", district: 1)
    assert_equal [ "Jordan Ellis", "Pat Rivers" ], nh1.candidates.order(:id).map(&:name)
    assert_equal %w[dem rep], nh1.candidates.order(:id).map(&:party)
    assert_equal [ false, true ], nh1.candidates.order(:id).map(&:incumbent)

    nh_run = ScrapeRun.find_by!(source: NH)
    assert_equal "succeeded", nh_run.status
    assert_equal 2, nh_run.fetched_count
    assert_equal 2, nh_run.new_count

    ny_run = ScrapeRun.find_by!(source: NY)
    assert_equal "succeeded", ny_run.status
    assert_equal 0, ny_run.fetched_count
  end

  test "a district absent from the page's output is left completely untouched" do
    _nh1, nh2 = nh_races
    stale = Candidate.create!(race: nh2, name: "Seeded Placeholder", party: :dem, incumbent: true)
    stub_wikipedia_page(NH, body: house_candidates_page_html(districts: [
      { number: 1, nominees: [ [ "Jordan Ellis", "Democratic" ], [ "Pat Rivers", "Republican" ] ] }
    ]))

    Ingest::SyncHouseCandidatesJob.perform_now

    assert_equal [ stale ], nh2.candidates.reload.to_a, "district 2 was never in the parser's output — no prune, no delete"
    run = ScrapeRun.find_by!(source: NH)
    assert_equal 1, run.fetched_count
    assert_equal "succeeded", run.status
  end

  test "logs a warning and keeps going when the page names a district we hold no race for" do
    nh_races([ 1 ])
    stub_wikipedia_page(NH_SINGLE, body: house_candidates_page_html(districts: [
      { number: 1, nominees: [ [ "Jordan Ellis", "Democratic" ], [ "Pat Rivers", "Republican" ] ] },
      { number: 2, nominees: [ [ "Alex Chen", "Democratic" ], [ "Sam Torres", "Republican" ] ] }
    ]))

    Ingest::SyncHouseCandidatesJob.perform_now

    run = ScrapeRun.find_by!(source: NH_SINGLE)
    assert_equal "partial", run.status
    assert_equal 2, run.fetched_count
    assert_equal 1, run.new_count
    assert_match(/1 district\(s\) skipped/, run.error_message)
    assert_not Race.house.exists?(state: "NH", district: 2), "the job never creates a race on its own"
  end

  # ---------------------------------------------------------------------
  # One state's failure does not abort the sweep
  # ---------------------------------------------------------------------

  test "one state's page failing outright is recorded as failed, and the sweep carries on" do
    nh_races([ 1 ])
    stub_wikipedia_page(NH_SINGLE, status: 500)

    outcomes = Ingest::SyncHouseCandidatesJob.perform_now

    nh_run = ScrapeRun.find_by!(source: NH_SINGLE)
    assert_equal "failed", nh_run.status
    assert_match(/FetchFailed/, nh_run.error_message)

    assert_equal "succeeded", ScrapeRun.find_by!(source: NY).status
    assert_equal 2, outcomes.size, "the other state's sweep still ran"
  end

  test "a missing state page is recorded as partial, and the sweep carries on" do
    nh_races([ 1 ])
    stub_wikipedia_page(NH_SINGLE, status: 404)

    Ingest::SyncHouseCandidatesJob.perform_now

    nh_run = ScrapeRun.find_by!(source: NH_SINGLE)
    assert_equal "partial", nh_run.status
    assert_match(/page not available/, nh_run.error_message)
    assert_equal "succeeded", ScrapeRun.find_by!(source: NY).status
  end

  # ---------------------------------------------------------------------
  # Controller rulings: preserving caucus_with, and per-party pruning
  # ---------------------------------------------------------------------

  # Alaska's real infobox (house_alaska.html, also used by
  # HouseCandidatesParserTest) lists exactly two nominees: Nick Begich III
  # (rep) and Bill Hill (ind) — no caucus fact, because Wikipedia carries
  # none. Bill Hill's caucus_with is hand-set here the way an admin would set
  # it through Admin::CandidatesController for an Alaska-style independent,
  # and a third candidate — a minor Democrat the page never mentions — proves
  # the per-party prune at the same time.
  test "preserves a hand-set caucus_with and spares a candidate whose party the page never lists" do
    race = Race.create!(office: :house, state: "AK", district: 1, cycle: 2026,
                         slug: "house-2026-ak-01", baseline_margin: 0.0)
    Candidate.create!(race: race, name: "Nick Begich III", party: :rep, incumbent: true)
    Candidate.create!(race: race, name: "Bill Hill", party: :ind, caucus_with: :dem, incumbent: false)
    minor = Candidate.create!(race: race, name: "Write-In Minor", party: :dem, incumbent: false)

    stub_wikipedia_page(ALASKA, fixture: "house_alaska.html")

    Ingest::SyncHouseCandidatesJob.perform_now

    ak_run = ScrapeRun.find_by!(source: ALASKA)
    assert_equal 1, ak_run.new_count,
                 "the sync must actually have run against Alaska, or the asserts below hold vacuously"

    bill_hill = race.candidates.find_by!(name: "Bill Hill")
    assert_equal "dem", bill_hill.caucus_with,
                 "the parser carries no caucus_with key; the job must merge the hand-set value forward"
    assert Candidate.exists?(minor.id),
           "the page's two nominees are rep and ind — dem is not a listed party this run"
  end
end
