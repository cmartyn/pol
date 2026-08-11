# The dashboard (root): both chambers at a glance, the national environment,
# the biggest movers since last week, and the newsroom's latest output.
class HomeController < PublicController
  def index
    @latest_run = ModelRun.succeeded.latest.first

    # Each chamber card looks up its own ChamberForecast/histogram, wrapped
    # in its own `<% cache %>` block — see app/views/home/_chamber_card.html.erb —
    # so a cache hit skips that query rather than paying it here unconditionally.

    # The current poll average, not anything tied to @latest_run — see
    # Site::Charts::PollsScatter for why a live Averager call and a stored
    # forecast are deliberately different numbers.
    @national_environment = Forecast::Averager.new(as_of: Time.current).for_generic_ballot

    @movers = Site::Movers.call
    @dispatches = Dispatch.published.recent_first.limit(5).includes(:race)
  end
end
