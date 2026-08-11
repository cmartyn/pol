module Admin
  class ScrapeRunsController < BaseController
    def index
      @scrape_runs = ScrapeRun.recent_first
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
