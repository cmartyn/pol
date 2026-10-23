module Admin
  class PollstersController < BaseController
    before_action :set_pollster, only: [ :edit, :update ]

    def index
      @pollsters = Pollster.order(:name)
      @poll_counts = Poll.from_current_sources.group(:pollster_id).count
    end

    def edit
      @dispatches = Dispatch.published.citing_any(@pollster.polls.pluck(:id)).recent_first
    end

    def update
      if @pollster.update(params.require(:pollster).permit(:excluded, :exclusion_reason, :exclusion_source_url))
        notice = if @pollster.saved_change_to_excluded_at?
          "Pollster #{@pollster.excluded? ? 'excluded' : 'reinstated'}. A forecast update is queued."
        else
          "Pollster details saved."
        end
        redirect_to edit_admin_pollster_path(@pollster), notice: notice
      else
        edit
        render :edit, status: :unprocessable_entity
      end
    end

    private
      def set_pollster
        @pollster = Pollster.find(params[:id])
      end
  end
end
