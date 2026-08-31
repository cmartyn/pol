module Admin
  # /admin — the editor's at-a-glance view of everything the autonomous
  # pipeline did since they last looked: last scrape, last model run,
  # today's publishing, today's skips, and the kill switch state.
  class DashboardController < BaseController
    def index
      @last_scrape = ScrapeRun.recent_first.first
      @last_run = ModelRun.latest.first
      @last_run_chamber_forecasts = @last_run&.succeeded? ? @last_run.chamber_forecasts.excl_internals.index_by(&:chamber) : {}

      @dispatches_today = Newsroom::Caps.published_today.count
      @skips_today_by_reason = NewsroomSkip.where(created_at: Newsroom::Caps.day_range).group(:reason).count

      @kill_switch = KillSwitchStatus.call
    end
  end
end
