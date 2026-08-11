module Admin
  # The newsroom's own record of everything it decided NOT to publish and
  # why (NewsroomSkip.record! — every skip is written here, nothing goes
  # quiet silently). Filterable by reason/kind; the header groups today's
  # (ET, matching Newsroom::Caps' own day-cutting) skips by reason so a
  # quiet day and a broken day look different at a glance.
  class NewsroomSkipsController < BaseController
    def index
      @skips = NewsroomSkip.recent_first.includes(:race)
      @skips = @skips.where(reason: params[:reason]) if params[:reason].present?
      @skips = @skips.where(kind: params[:kind]) if params[:kind].present?

      @today_counts_by_reason = NewsroomSkip.where(created_at: Newsroom::Caps.day_range).group(:reason).count
    end
  end
end
