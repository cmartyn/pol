module Admin
  class ScrapeRunsController < BaseController
    # A sweep writes one row per source, and Phase 8 took that from 36 sources
    # to 69 — twelve times a day. Listing every run ever would be a page that
    # grows by 828 rows a day and a refusal summary computed over all of them,
    # so the page shows a window: a little over two full sweeps, which is
    # enough to see whether a source that refused everything did it twice.
    WINDOW = 150

    def index
      @scrape_runs = ScrapeRun.recent_first.limit(WINDOW)
      @window = WINDOW
      @total = ScrapeRun.count
    end

    # The job already handles everything about actually scraping (per-source
    # failures, the ScrapeRun rows themselves) — this only enqueues it, so
    # the flash says "enqueued", not "done".
    def create
      Ingest::ScrapeAllJob.perform_later
      redirect_to admin_scrape_runs_path, notice: "Scrape enqueued."
    end
  end
end
