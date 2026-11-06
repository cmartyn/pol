# The dashboard (root): both chambers at a glance, the national environment,
# the biggest movers since last week, and the newsroom's latest output.
class HomeController < PublicController
  edge_cache

  def index
    @latest_run = ModelRun.published.first

    # Each chamber card looks up its own ChamberForecast/histogram, wrapped
    # in its own `<% cache %>` block — see app/views/home/_chamber_card.html.erb —
    # so a cache hit skips that query rather than paying it here unconditionally.

    # Reconstruct the supporting average from the polls available at the
    # archived run's start, with the exclusions and effects it applied.
    polls = Poll.published_corpus.for_generic_ballot.includes(:poll_results)
    house_effects = HouseEffect.applied_lookup(@latest_run)
    @national_environment = Forecast::Averager.new(
      as_of: ForecastArchive.polling_time, house_effects: house_effects, excluded_pollster_ids: ForecastArchive.excluded_pollster_ids
    ).for_generic_ballot(polls: polls)
    # The toggled-on view of the same number, adjusted with the shift the
    # run on show estimated (or the prior, before any run has).
    @national_environment_incl = Forecast::Averager.new(
      as_of: ForecastArchive.polling_time, house_effects: house_effects, excluded_pollster_ids: ForecastArchive.excluded_pollster_ids,
      internals: :adjusted,
      internals_shift: @latest_run&.internals_shift || Pol::Params.fetch!(:internals, :prior_shift).to_f
    ).for_generic_ballot(polls: polls)

    @movers = Site::Movers.call unless ForecastArchive.active?
    @dispatches = Dispatch.published.recent_first.limit(5).includes(:race)
    @dispatches = @dispatches.where(published_at: ..ForecastArchive.finished_at) if ForecastArchive.active?
    @corpus_note = Site::CorpusNote.new
  end
end
