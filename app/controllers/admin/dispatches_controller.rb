module Admin
  # Every dispatch, every status (unlike the public feed, which only shows
  # published ones) — this is where the editor sees what the newsroom wrote,
  # corrects it, or pulls it. Retraction is the editor's main lever: the
  # dispatch stays in the newsroom's own memory (Dispatch#retracted? is
  # surfaced to the writer via Newsroom::Context so nothing gets re-asserted
  # the moment after it's pulled) rather than being deleted.
  class DispatchesController < BaseController
    before_action :set_dispatch, only: [ :show, :edit, :update, :retract ]

    def index
      @dispatches = Dispatch.recent_first.includes(:race)
      @dispatches = @dispatches.where(kind: params[:kind]) if params[:kind].present?
      @dispatches = @dispatches.where(status: params[:status]) if params[:status].present?
      @dispatches = @dispatches.where(race_id: params[:race_id]) if params[:race_id].present?

      @races = Race.order(:office, :state, :district)
    end

    def show
      @cited_polls = Poll.where(id: @dispatch.cited_poll_ids).includes(:pollster)
    end

    def edit
    end

    # Saving always sets edited_at, whether or not the content actually
    # changed — the public byline's "Updated by the editor" is a promise
    # about who last touched this piece, not a diff. The model-level
    # headline cap (Dispatch#headline_within_max_chars) is what stands
    # between the writer's cap and the editor's: it stays live here too.
    def update
      if @dispatch.update(dispatch_params.merge(edited_at: Time.current))
        touch_race_for_cache
        redirect_to admin_dispatch_path(@dispatch), notice: "Dispatch updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def retract
      @dispatch.update!(status: :retracted)
      touch_race_for_cache
      redirect_to admin_dispatch_path(@dispatch), notice: "Dispatch retracted."
    end

    private
      def set_dispatch
        @dispatch = Dispatch.find(params[:id])
      end

      # The cache-consistency rule (Phase 4), extended to editing/retracting a
      # dispatch that is NOT the race's current latest published one: the race
      # page's cache key (app/views/races/show.html.erb) is keyed on
      # @latest_dispatch, which does not change when an older piece is edited
      # or pulled, so without this the cached feed would keep rendering
      # content a `.update` or `.retract` had just changed underneath it —
      # same failure Admin::UpdatePoll#update! already guards against for
      # polls. A no-op for a national dispatch, which has no race.
      def touch_race_for_cache
        @dispatch.race&.touch
      end

      def dispatch_params
        params.require(:dispatch).permit(:headline, :dek, :body_markdown)
      end
  end
end
