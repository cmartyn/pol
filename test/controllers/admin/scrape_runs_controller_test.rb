require "test_helper"

class Admin::ScrapeRunsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "index lists scrape runs" do
    get admin_scrape_runs_path
    assert_response :success
    assert_select "[data-testid='admin-scrape-run-row']", count: ScrapeRun.count
  end

  # A sweep is 69 rows and runs twelve times a day, so the page has to be a
  # window rather than the whole history.
  test "index lists at most a window's worth of runs and says so" do
    template = scrape_runs(:senate_scrape_run)
    (Admin::ScrapeRunsController::WINDOW + 5 - ScrapeRun.count).times do |index|
      ScrapeRun.create!(template.attributes.except("id", "created_at", "updated_at")
                                .merge("source" => "filler #{index}", "finished_at" => index.minutes.ago))
    end

    get admin_scrape_runs_path

    assert_select "[data-testid='admin-scrape-run-row']", count: Admin::ScrapeRunsController::WINDOW
    assert_select "[data-testid='admin-scrape-runs-window']", text: /most recent #{Admin::ScrapeRunsController::WINDOW}/
  end

  test "index shows an honest empty state with none yet" do
    ScrapeRun.delete_all
    get admin_scrape_runs_path
    assert_select "[data-testid='admin-scrape-runs-empty']"
  end

  test "index names every refusal reason, in English and in machine form" do
    get admin_scrape_runs_path

    assert_select "[data-testid='admin-scrape-run-reason'][data-reason='primary_only_table']",
                  text: /primary field ×4/
    assert_select "[data-testid='admin-scrape-run-reason'][data-reason='layout_unrecognized']",
                  text: /table layout not recognised ×1/
  end

  test "index tells a page with no polling section apart from a page we refused" do
    get admin_scrape_runs_path

    assert_select "[data-testid='admin-scrape-run-empty-page']", text: /no polling section/
    assert_select "[data-testid='admin-scrape-run-refused']", count: ScrapeRun.refusing.count
  end

  test "index leads with the sources that refused a table" do
    get admin_scrape_runs_path

    assert_select "[data-testid='admin-scrape-refusals']" do
      assert_select "h2", text: /3 sources refused a table/
      # Only the two that need looking at are listed by name; the routine one
      # is a count, so the panel stays small as the sweep grows.
      assert_select "[data-testid='admin-scrape-refusal-summary-row']", count: 2
      assert_select "[data-testid='admin-scrape-refusal-summary-row']", text: /Colorado.*read no polls/
      assert_select "[data-testid='admin-scrape-refusals-routine']", text: /1 other source/
    end
  end

  # The window holds a couple of sweeps, so every source appears in it more
  # than once. Counting rows would report more sources refusing than the sweep
  # has sources, and list Colorado two or three times.
  test "index counts sources that refused a table, not runs" do
    before = ScrapeRun.recent_first.select(&:refused_tables?).map(&:source)
    sweep_again

    get admin_scrape_runs_path

    assert_equal 2, ScrapeRun.refusing.where(source: before.first).count, "the source is in the window twice"
    assert_select "[data-testid='admin-scrape-refusals'] h2", text: /#{before.size} sources refused a table/
    assert_select "[data-testid='admin-scrape-refusal-summary-row']", count: 2
    assert_select "[data-testid='admin-scrape-refusals-routine']", text: /1 other source/
  end

  # A second run of every source, five minutes later — the same shape a real
  # sweep leaves behind.
  def sweep_again
    ScrapeRun.recent_first.to_a.each do |run|
      ScrapeRun.create!(run.attributes.except("id", "created_at", "updated_at")
                           .merge("started_at" => run.started_at + 5.minutes,
                                  "finished_at" => run.finished_at + 5.minutes))
    end
  end

  test "index shows no refusal panel when nothing refused anything" do
    ScrapeRun.refusing.destroy_all

    get admin_scrape_runs_path

    assert_select "[data-testid='admin-scrape-refusals']", count: 0
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
