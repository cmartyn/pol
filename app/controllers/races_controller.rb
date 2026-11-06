# The three race-facing public pages: the sortable Senate table, the
# searchable 435-district House table, and a single race's detail page.
class RacesController < PublicController
  edge_cache
  before_action :results_filter, only: [ :senate, :house ]

  def senate
    @latest_run = ModelRun.published.first
    # Normalizes sort/direction only (no query) — the view calls
    # Site::SenateTable.build itself, inside its `<% cache %>` block, so a
    # cache hit skips that query entirely instead of paying for it here
    # unconditionally. An unknown or absent ?sort= falls back to "state"
    # inside Site::SenateTable, and the column headers need to know that
    # actually happened to link and highlight themselves correctly.
    table = Site::SenateTable.new(sort: params[:sort], direction: params[:dir])
    @sort = table.sort
    @direction = table.direction
  end

  def house
    @latest_run = ModelRun.published.first
    # Mirrors #senate: normalize sort/direction only. Site::HouseTable.build
    # and the chamber summary's ChamberForecast/histogram lookup both happen
    # inside the view's `<% cache %>` blocks, so a hit skips those queries
    # rather than paying for them here regardless. The column headers need to
    # know which sort actually took effect to link and highlight correctly.
    table = Site::HouseTable.new(sort: params[:sort], direction: params[:dir])
    @sort = table.sort
    @direction = table.direction
  end

  def show
    @race = Race.forecast_board.includes(:candidates).find_by!(slug: params[:slug])
    @latest_run = ModelRun.published.first
    # A cheap single-row lookup, only for the cache key below — the full
    # dispatches list (and everything else this page needs: forecast, polls,
    # timeline, poll-scatter) is built inside the view's `<% cache %>` block,
    # so a cache hit skips all of it rather than this controller loading it
    # unconditionally on every request. See app/views/races/show.html.erb.
    @result = @race.race_result if ForecastArchive.active?
    @latest_dispatch = @race.dispatches.published.recent_first.first
  end

  private
    def results_filter
      return unless ForecastArchive.active?

      @outstanding_only = params[:status] == "outstanding"
      @results_version = RaceResult.joins(:race).where(races: { office: action_name }).cache_key_with_version
    end
end
