# The dashboard (root): both chambers at a glance, the national environment,
# the biggest movers since last week, and the newsroom's latest output.
class HomeController < PublicController
  def index
    @latest_run = ModelRun.succeeded.latest.first

    if @latest_run
      chamber_forecasts = ChamberForecast.where(model_run_id: @latest_run.id).index_by(&:chamber)
      @senate_chamber_forecast = chamber_forecasts["senate"]
      @house_chamber_forecast = chamber_forecasts["house"]
      @senate_histogram = @senate_chamber_forecast && Site::Charts::SeatHistogram.build(@senate_chamber_forecast)
      @house_histogram = @house_chamber_forecast && Site::Charts::SeatHistogram.build(@house_chamber_forecast)
    end

    # The current poll average, not anything tied to @latest_run — see
    # Site::Charts::PollsScatter for why a live Averager call and a stored
    # forecast are deliberately different numbers.
    @national_environment = Forecast::Averager.new(as_of: Time.current).for_generic_ballot

    @movers = Site::Movers.call
    @dispatches = Dispatch.published.recent_first.limit(5).includes(:race)
  end
end
