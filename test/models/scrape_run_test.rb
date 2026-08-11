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
end
