# The dashboard (root): both chambers at a glance, the national environment,
# the biggest movers since last week, and the newsroom's latest output.
class HomeController < PublicController
  edge_cache

  def index
    @latest_run = ModelRun.succeeded.latest.first

    # Each chamber card looks up its own ChamberForecast/histogram, wrapped
    # in its own `<% cache %>` block — see app/views/home/_chamber_card.html.erb —
    # so a cache hit skips that query rather than paying it here unconditionally.

    # The current poll average, not anything tied to @latest_run — see
    # Site::Charts::PollsScatter for why a live Averager call and a stored
    # forecast are deliberately different numbers. House effects still apply:
    # the lookup comes from @latest_run's stored, applied effects (the same
    # mixed-vintage pattern races/show.html.erb uses for PollsScatter), so
    # this matches methodology step 2 — a poll's lean is subtracted before it
    # enters any average this site publishes, not only the ones tied to a run.
    house_effects = HouseEffect.applied_lookup(@latest_run)
    @national_environment = Forecast::Averager.new(
      as_of: Time.current, house_effects: house_effects
    ).for_generic_ballot
    # The toggled-on view of the same number, adjusted with the shift the
    # run on show estimated (or the prior, before any run has).
    @national_environment_incl = Forecast::Averager.new(
      as_of: Time.current, house_effects: house_effects,
      internals: :adjusted,
      internals_shift: @latest_run&.internals_shift || Pol::Params.fetch!(:internals, :prior_shift).to_f
    ).for_generic_ballot

    @movers = Site::Movers.call
    @dispatches = Dispatch.published.recent_first.limit(5).includes(:race)
    @corpus_note = Site::CorpusNote.new
  end
end
