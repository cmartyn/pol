require "test_helper"

class ScrapeRunTest < ActiveSupport::TestCase
  test "status enum round-trips every value" do
    ScrapeRun.statuses.each_key do |value|
      run = ScrapeRun.new(status: value)
      assert_equal value, run.status
    end
  end

  test "recent_first orders by finished_at descending" do
    older = ScrapeRun.create!(
      source: "older source", status: :succeeded, started_at: "2026-07-01 08:00:00", finished_at: "2026-07-01 08:01:00"
    )

    ordered = ScrapeRun.where(id: [ older.id, scrape_runs(:senate_scrape_run).id ]).recent_first
    assert_equal [ scrape_runs(:senate_scrape_run), older ], ordered.to_a
  end

  test "a run with no refusals recorded reads as neither dark nor alarming" do
    run = scrape_runs(:senate_scrape_run)

    assert_equal 0, run.refused_count
    assert_empty run.refusal_reasons
    assert_not run.refused_tables?
    assert_not run.no_polling_section?
    assert_not run.dark?
    assert_not run.refusal_alarm?
  end

  test "refusals are listed most-refused first, with plain English beside the machine name" do
    run = scrape_runs(:district_scrape_run)

    assert_equal [
      [ "primary_only_table", 4, "primary field" ],
      [ "generic_candidate_column", 1, "placeholder candidate column" ]
    ], run.refusals
  end

  test "a page with no polling section refused nothing" do
    run = scrape_runs(:no_polling_section_scrape_run)

    assert run.no_polling_section?
    assert_not run.refused_tables?
    assert_not run.dark?, "there was nothing to go dark on"
  end

  test "refusing every table and reading nothing is what dark means" do
    run = scrape_runs(:dark_scrape_run)

    assert run.dark?
    assert run.refusal_alarm?
  end

  test "a layout we could not read is an alarm even when the page yielded polls" do
    run = scrape_runs(:unreadable_scrape_run)

    assert_not run.dark?, "it did read polls"
    assert run.refusal_alarm?
    assert_equal({ "layout_unrecognized" => 1 }, run.unreadable_refusals)
  end

  test "an unknown reason still renders, under its machine name" do
    run = ScrapeRun.new(refusal_reasons: { "reason_from_the_future" => 2 })

    assert_equal [ [ "reason_from_the_future", 2, "reason_from_the_future" ] ], run.refusals
  end

  test "every reason the parser or the feed mapper can emit has a label" do
    emittable = Ingest::PollTableParser::REFUSAL_REASONS.map(&:to_s) +
                Ingest::Nyt::Mapper::REFUSAL_REASONS.map(&:to_s)

    assert_equal emittable.sort.uniq, ScrapeRun::REASON_LABELS.keys.sort
  end
end
