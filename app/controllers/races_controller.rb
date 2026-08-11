# The three race-facing public pages: the sortable Senate table, the
# searchable 435-district House table, and a single race's detail page.
class RacesController < PublicController
  def senate
    @latest_run = ModelRun.succeeded.latest.first
    # Built directly (not via .build) so the view can read back the
    # normalized sort/direction — an unknown or absent ?sort= falls back to
    # "state" inside Site::SenateTable, and the column headers need to know
    # that actually happened to link and highlight themselves correctly.
    table = Site::SenateTable.new(sort: params[:sort], direction: params[:dir])
    @sort = table.sort
    @direction = table.direction
    @rows = table.build
  end

  def house
    @latest_run = ModelRun.succeeded.latest.first
    @house_chamber_forecast = @latest_run && ChamberForecast.find_by(model_run_id: @latest_run.id, chamber: :house)
    @histogram = @house_chamber_forecast && Site::Charts::SeatHistogram.build(@house_chamber_forecast)
    @rows = Site::HouseTable.build
  end

  def show
    @race = Race.includes(:candidates).find_by!(slug: params[:slug])
    @latest_run = ModelRun.succeeded.latest.first
    @forecast = @race.latest_forecast
    @polls = @race.polls.recent_first.includes(:poll_results, :pollster)
    @timeline = Site::Charts::Timeline.build(race: @race)
    @polls_scatter = Site::Charts::PollsScatter.build(race: @race, polls: @polls, as_of: Time.current)
    @dispatches = @race.dispatches.published.recent_first.includes(:model_run)
  end
end
