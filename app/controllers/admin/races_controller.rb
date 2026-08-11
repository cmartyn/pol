module Admin
  # Race index/edit — lean, baseline, incumbent, open/special/uncontested
  # flags, plus inline candidate management (Admin::CandidatesController, a
  # small sub-resource: real per-row forms rather than JS-driven dynamic
  # nested-attribute rows, so it stays plain server-rendered HTML). None of
  # this feeds the site directly — see the guardrail note on the edit page:
  # it feeds the NEXT model run.
  class RacesController < BaseController
    def index
      @races = Race.order(:office, :state, :district)
      @races = @races.where(office: params[:office]) if params[:office].present?
      @races = @races.where(state: matching_state_codes(params[:state])) if params[:state].present?

      @poll_counts = Poll.group(:race_id).count
    end

    def edit
      @race = Race.includes(:candidates).find(params[:id])
    end

    def update
      @race = Race.includes(:candidates).find(params[:id])
      if @race.update(race_params)
        redirect_to edit_admin_race_path(@race), notice: "Race updated."
      else
        render :edit, status: :unprocessable_entity
      end
    # A blank incumbent_party/uncontested_party is handled gracefully by
    # Rails enums (casts to nil) — only a value outside the enum's mapping
    # raises, which a real <select> never submits on its own. Defense in
    # depth against a hand-crafted request, not a path the form itself can
    # reach.
    rescue ArgumentError => e
      @race.errors.add(:base, e.message)
      render :edit, status: :unprocessable_entity
    end

    private
      def race_params
        params.require(:race).permit(
          :lean, :baseline_margin, :baseline_imputed, :incumbent_name, :incumbent_party,
          :open_seat, :special, :uncontested, :uncontested_party
        )
      end

      # "Maine" and "ME" both find races(:senate_maine): a state code or
      # full name, matched case-insensitively as a substring against
      # Race::STATE_NAMES (a static Ruby hash, not a DB column, so this
      # resolves to a plain IN query rather than something SQL has to do).
      def matching_state_codes(query)
        needle = query.strip.downcase
        Race::STATE_NAMES.select { |code, name| code.downcase.include?(needle) || name.downcase.include?(needle) }.keys
      end
  end
end
