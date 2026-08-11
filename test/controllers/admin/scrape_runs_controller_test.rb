require "test_helper"

class Admin::ScrapeRunsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "index lists scrape runs" do
    get admin_scrape_runs_path
    assert_response :success
    assert_select "[data-testid='admin-scrape-run-row']", count: ScrapeRun.count
  end

  test "index shows an honest empty state with none yet" do
    ScrapeRun.delete_all
    get admin_scrape_runs_path
    assert_select "[data-testid='admin-scrape-runs-empty']"
  end

  test "create enqueues Ingest::ScrapeAllJob and redirects with a flash" do
    assert_enqueued_with(job: Ingest::ScrapeAllJob, queue: "default") do
      post admin_scrape_runs_path
    end

    assert_redirected_to admin_scrape_runs_path
    follow_redirect!
    assert_select "[data-testid='admin-flash-notice']", text: /enqueued/i
  end
end
