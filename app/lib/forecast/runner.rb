# One model run, end to end: open a run, average the generic ballot, build a
# central estimate for every race, simulate, write the forecasts, close the run.
#
# Everything a run depended on is recorded on the run itself — the full
# parameter tree in params_snapshot and the RNG seed in rng_seed — so any run
# can be reproduced exactly from its own row.
class Forecast::Runner
  # Governor races are in the schema but not in the 2026 board, and they belong
  # to no chamber; the forecast covers the two chambers it models.
  MODELLED_OFFICES = %i[senate house].freeze

  # Raised when another run is already in flight. Not a failed run — there is
  # no run row to mark, because the database refused to create one. Callers
  # decide what to say about it; nobody should treat it as an error worth
  # retrying, because the run that is already going will produce the numbers.
  AlreadyRunning = Class.new(StandardError)

  def self.call(**options)
    new(**options).call
  end

  def initialize(trigger:, as_of: nil, seed: nil, n_sims: nil, logger: Rails.logger,
                 raise_on_error: !Rails.env.production?)
    @trigger = trigger.to_sym
    @as_of = (as_of || Date.current).to_date
    @seed = seed
    @n_sims = n_sims
    @logger = logger
    @raise_on_error = raise_on_error
  end

  attr_reader :trigger, :as_of, :logger
  # Set during the run, for callers that want to report on it (bin/rails pol:model).
  # The un-suffixed readers carry the DEFAULT variant (internals excluded) —
  # the published numbers — so nothing that reported on a run before variants
  # existed has to know they do now. `variants` holds both.
  attr_reader :model_run, :house_effects, :variants, :internals_estimate

  def default_variant = variants&.fetch(:excl_internals, nil)
  def generic_ballot = default_variant&.generic_ballot
  def national_env = default_variant&.national_env
  def race_models = default_variant&.race_models
  def simulation = default_variant&.simulation

  # Everything one variant computed, from its own averager: the corpus and
  # the internals treatment differ, the seed and the race board do not.
  Variant = Struct.new(:generic_ballot, :national_env, :race_models, :simulation, keyword_init: true)

  def call
    @model_run = start_run!

    begin
      forecast!
      model_run
    rescue StandardError => error
      fail_run!(error)
      raise if @raise_on_error

      model_run
    end
  end

  private
    # Opening a run is the concurrency guard, and it is the database that
    # enforces it: `index_model_runs_on_single_running` is a partial unique
    # index over status = running, so of two workers inserting in the same
    # instant exactly one succeeds. Asking "is one running?" first and
    # inserting second would leave a window between the two where both see
    # false. Every path in — the job, bin/rails pol:model, a console — goes
    # through here and is covered by the same guarantee.
    def start_run!
      release_stale_run!

      ModelRun.create!(
        status: :running,
        trigger: trigger,
        started_at: Time.current,
        params_snapshot: Pol::Params.to_h,
        rng_seed: @seed || SecureRandom.random_number(2**62)
      )
    rescue ActiveRecord::RecordNotUnique
      raise AlreadyRunning, "a forecast run is already in flight"
    end

    # Without this, one killed worker freezes the forecast permanently: the row
    # it left behind says `running`, the unique index refuses every later run,
    # and the site keeps serving plausible stale numbers with nothing to
    # indicate anything is wrong. A run older than stale_run_minutes cannot be
    # alive — a full run takes under two seconds — so the next run fails it and
    # takes over. The row keeps its own error_message, so the wreck is visible
    # afterwards rather than silently swept away.
    def release_stale_run!
      cutoff = Pol::Params.fetch!(:simulation, :stale_run_minutes).minutes.ago
      stale = ModelRun.running.where("started_at IS NULL OR started_at < ?", cutoff)

      released = stale.update_all(
        status: ModelRun.statuses.fetch("failed"),
        error_message: "abandoned: still running after #{Pol::Params.fetch!(:simulation, :stale_run_minutes)} " \
                       "minutes, failed by the run that took over",
        finished_at: Time.current,
        updated_at: Time.current
      )

      logger.warn("Forecast::Runner: released #{released} abandoned run(s)") if released.positive?
    end

    def forecast!
      # Before any averaging, and from unadjusted averages — the single pass
      # described in Forecast::HouseEffects. Estimated once, on the
      # internals-excluded corpus, and applied in both variants; the
      # internals shift is likewise one number per run.
      @house_effects = Forecast::HouseEffects.call(as_of: as_of)
      @internals_estimate = Forecast::Internals.estimate(as_of: as_of)

      # The default variant first, computed exactly as a run always computed:
      # same averager construction, same race order, its own simulator on the
      # run's seed. The incl_internals pass reuses the seed deliberately —
      # identical shared-error draws make the toggle's delta a paired
      # comparison of the two corpora, never resampling noise.
      @variants = {
        excl_internals: compute_variant(internals: :exclude),
        incl_internals: compute_variant(internals: :adjusted)
      }

      # One transaction for both variants: the toggle must never find one
      # published without the other.
      ActiveRecord::Base.transaction do
        write_house_effects
        @variants.each do |variant, computed|
          write_forecasts(variant, computed.simulation)
          write_chamber_forecasts(variant, computed.simulation)
        end
        model_run.update!(
          status: :succeeded, finished_at: Time.current,
          params_snapshot: model_run.params_snapshot.merge("internals_estimate" => @internals_estimate.to_snapshot)
        )
      end

      logger.info(
        "Forecast::Runner: run #{model_run.id} (#{trigger}) forecast #{race_models.size} races ×2 variants, " \
        "national env #{format('%+.2f', national_env)}, " \
        "#{@house_effects.applied_count} of #{@house_effects.effects.size} house effects applied, " \
        "internals shift #{format('%.2f', @internals_estimate.shift)} (#{@internals_estimate.pair_count} pairs), " \
        "seed #{model_run.rng_seed}"
      )
    end

    def compute_variant(internals:)
      averager = Forecast::Averager.new(
        as_of: as_of, house_effects: @house_effects.lookup,
        internals: internals, internals_shift: @internals_estimate.shift
      )
      generic_ballot = averager.for_generic_ballot(polls: generic_polls)
      national_env = national_environment(generic_ballot)
      race_models = build_race_models(averager, national_env)
      simulation = Forecast::Simulator.new(
        entries: race_models.map(&:to_entry),
        seed: model_run.rng_seed,
        as_of: as_of,
        n_sims: @n_sims
      ).call

      Variant.new(generic_ballot: generic_ballot, national_env: national_env,
                  race_models: race_models, simulation: simulation)
    end

    # The national environment is the generic-ballot average. With no
    # generic-ballot polls at all it falls back to the last national House
    # vote, which leaves every district sitting at its 2024 baseline — a
    # neutral starting point, rather than the artificial swing that assuming a
    # tied national vote would produce.
    def national_environment(average)
      return average.mean_margin if average.polled?

      fallback = Pol::Params.fetch!(:fundamentals, :house_national_margin_2024)
      logger.warn("Forecast::Runner: no generic-ballot polls in window; national environment falls back to #{fallback}")
      fallback
    end

    # Races in id order: the simulator takes its draws in the order it is
    # handed the entries, so a stable order is part of what makes a seed
    # reproduce a run. Candidates and polls are loaded in two queries rather
    # than 470 apiece — once for the run, shared by both variants; each
    # variant's averager decides what to do with the internals among them.
    def build_race_models(averager, national_env)
      races.map do |race|
        Forecast::RaceModel.new(
          race: race,
          national_env: national_env,
          averager: averager,
          polls: race_polls.fetch(race.id, [])
        )
      end
    end

    def races
      @races ||= Race.where(office: MODELLED_OFFICES).includes(:candidates).order(:id).to_a
    end

    def race_polls
      @race_polls ||= Poll.model_corpus.where(race_id: races.map(&:id)).includes(:poll_results).group_by(&:race_id)
    end

    def generic_polls
      @generic_polls ||= Poll.model_corpus.for_generic_ballot.includes(:poll_results).to_a
    end

    # In the run's own transaction, alongside the forecasts they produced, so
    # a forecast's inputs are reproducible from the run's own rows rather than
    # from whatever the estimator would say today.
    def write_house_effects
      rows = house_effects.rows_for(model_run.id)

      HouseEffect.insert_all!(rows) if rows.any?
    end

    def write_forecasts(variant, simulation)
      now = Time.current
      rows = simulation.races.map do |outcome|
        {
          model_run_id: model_run.id,
          variant: ::Forecast.variants.fetch(variant.to_s),
          race_id: outcome.race_id,
          p_dem_win: outcome.p_dem_win,
          p_rep_win: outcome.p_rep_win,
          p_other_win: outcome.p_other_win,
          mean_margin: outcome.mean_margin,
          margin_percentiles: outcome.percentiles,
          effective_poll_weight: outcome.weight,
          created_at: now,
          updated_at: now
        }
      end

      ::Forecast.insert_all!(rows) if rows.any?
    end

    # What still has to travel with these two rows, because everything
    # downstream — the homepage number, a dispatch headline, an API consumer —
    # reads p_dem_control without reading the model.
    #
    # Phase 10 replaced the single national error with 538's own
    # decomposition: national 3, regional 2 (census division), state 2, plus
    # each race's own, combining to 4.1231 of correlated error. What is still
    # missing is 538's fifth term, 2 points at the demographic-cluster level,
    # which needs a clustering of all 435 districts we have no data for — so
    # their correlated total is 4.5826 against our 4.1231.
    #
    # Measured as a controlled comparison on 2026-08-12 — runs 16 and 17, same
    # seed, same 975 polls, only the error model changed: House control
    # 96.6% → 93.1% and seat SD 13.6 → 17.4 across the change. A fifth
    # component of 2 points would take a further 0.4 to 3.4 points off the
    # House figure depending on how broadly it is assumed to correlate, so it
    # is a point or so firmer than a fuller model's, three at the outside, in
    # the direction of whichever party leads. The Senate's movement across the
    # same assumptions is inside sampling noise at 10,000 sims.
    # See docs/BUILD_NOTES.md Phase 10 §A and §C — and §H for the current
    # board, which is a different thing from that controlled comparison.
    def write_chamber_forecasts(variant, simulation)
      now = Time.current
      rows = simulation.chambers.map do |outcome|
        {
          model_run_id: model_run.id,
          variant: ChamberForecast.variants.fetch(variant.to_s),
          chamber: ChamberForecast.chambers.fetch(outcome.chamber.to_s),
          p_dem_control: outcome.p_dem_control,
          p_rep_control: outcome.p_rep_control,
          mean_dem_seats: outcome.mean_dem_seats,
          seat_histogram: outcome.seat_histogram,
          created_at: now,
          updated_at: now
        }
      end

      ChamberForecast.insert_all!(rows)
    end

    # A run that blew up says so on its own row: the site can tell "no forecast
    # yet" from "the forecast failed", and the error travels with the run.
    def fail_run!(error)
      logger.error("Forecast::Runner: run #{model_run&.id.inspect} failed — #{error.class}: #{error.message}")
      return if model_run.nil?

      model_run.update_columns(
        status: ModelRun.statuses.fetch("failed"),
        error_message: "#{error.class}: #{error.message}",
        finished_at: Time.current,
        updated_at: Time.current
      )
    end
end
