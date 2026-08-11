module Admin
  # The inline candidate management on a race's edit page — a small sub-
  # resource (real per-row create/update/destroy forms) rather than JS-
  # driven dynamic nested-attribute rows, so it stays plain server-rendered
  # HTML. Every action redirects back to the race's edit page; there is no
  # candidate page of its own.
  class CandidatesController < BaseController
    before_action :set_race

    def create
      candidate = @race.candidates.build(candidate_params)
      if candidate.save
        redirect_to edit_admin_race_path(@race), notice: "Candidate added."
      else
        redirect_to edit_admin_race_path(@race), alert: candidate.errors.full_messages.to_sentence
      end
    rescue ArgumentError => e
      redirect_to edit_admin_race_path(@race), alert: e.message
    end

    def update
      candidate = @race.candidates.find(params[:id])
      if candidate.update(candidate_params)
        redirect_to edit_admin_race_path(@race), notice: "Candidate updated."
      else
        redirect_to edit_admin_race_path(@race), alert: candidate.errors.full_messages.to_sentence
      end
    rescue ArgumentError => e
      redirect_to edit_admin_race_path(@race), alert: e.message
    end

    def destroy
      @race.candidates.find(params[:id]).destroy
      redirect_to edit_admin_race_path(@race), notice: "Candidate removed."
    rescue ActiveRecord::InvalidForeignKey
      # A candidate with poll results (poll_results.candidate_id) is protected
      # by the DB's foreign key with no ON DELETE clause, so #destroy raises
      # rather than silently orphaning those rows. That is the right outcome —
      # this is real data, not a bug — but it should not be an unhandled 500.
      redirect_to edit_admin_race_path(@race),
                  alert: "Candidate has poll results; reassign or delete those polls first."
    end

    private
      def set_race
        @race = Race.find(params[:race_id])
      end

      def candidate_params
        params.require(:candidate).permit(:name, :party, :caucus_with, :incumbent)
      end
  end
end
