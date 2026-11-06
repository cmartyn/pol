class Admin::RaceResultsController < Admin::BaseController
  def update
    return head :not_found unless ForecastArchive.active?
    @race = Race.forecast_board.find(params[:race_id])
    input = params.expect(result: [ :status, :candidate, :source_url, :decided_at ])
    @result_input = input
    RaceResult.transaction do
      result = @race.race_result || RaceResult.for_race!(@race)
      result.edit_call!(status: input[:status], candidate: input[:candidate], source_url: input[:source_url],
        decided_at: input[:decided_at], editor: Current.user)
    end
    redirect_to edit_admin_race_path(@race), notice: "Election result saved."
  rescue ArgumentError => error
    @race.reload
    @result_error = error.message
    render "admin/races/edit", status: :unprocessable_entity
  end
end
