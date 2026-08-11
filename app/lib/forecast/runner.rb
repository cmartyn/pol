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
  attr_reader :model_run, :national_env, :generic_ballot, :simulation, :race_models

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
      averager = Forecast::Averager.new(as_of: as_of)
      @generic_ballot = averager.for_generic_ballot
      @national_env = national_environment(@generic_ballot)
      @race_models = build_race_models(averager)
      @simulation = Forecast::Simulator.new(
        entries: @race_models.map(&:to_entry),
        seed: model_run.rng_seed,
        as_of: as_of,
        n_sims: @n_sims
      ).call

      ActiveRecord::Base.transaction do
        write_forecasts
        write_chamber_forecasts
        model_run.update!(status: :succeeded, finished_at: Time.current)
      end

      logger.info(
        "Forecast::Runner: run #{model_run.id} (#{trigger}) forecast #{@race_models.size} races, " \
        "national env #{format('%+.2f', national_env)}, seed #{model_run.rng_seed}"
      )
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
    # than 470 apiece.
    def build_race_models(averager)
      races = Race.where(office: MODELLED_OFFICES).includes(:candidates).order(:id).to_a
      polls = Poll.where(race_id: races.map(&:id)).includes(:poll_results).group_by(&:race_id)

      races.map do |race|
        Forecast::RaceModel.new(
          race: race,
          national_env: national_env,
          averager: averager,
          polls: polls.fetch(race.id, [])
        )
      end
    end

    def write_forecasts
      now = Time.current
      rows = simulation.races.map do |outcome|
        {
          model_run_id: model_run.id,
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

    # A caveat that has to travel with these two rows, because everything
    # downstream — the homepage number, a dispatch headline, an API consumer —
    # reads p_dem_control without reading the model.
    #
    # v1 correlates races through ONE shared national error. 538's House model
    # uses four correlated terms (national 3, regional 2, state 2,
    # demographic-cluster 2, combining to 4.58 against our 2.5). The missing
    # correlation does not average away over 435 districts, so the House seat
    # distribution here is too narrow and p_dem_control for the House is
    # systematically too confident, in the direction of whichever party is
    # ahead. Measured on the live board: 96.3% here against 83.9% at 538's
    # correlated total, seat SD 13.6 against 25.4. The Senate is affected too,
    # by roughly 7 points, but less: 35 races cannot average away as much.
    #
    # The fix is a regional or state-level shared term — a change to the
    # model's structure, not to a constant, and deliberately deferred. Until
    # then, anything that publishes these numbers should say so.
    # See docs/BUILD_NOTES.md Phase 3 §A4.
    def write_chamber_forecasts
      now = Time.current
      rows = simulation.chambers.map do |outcome|
        {
          model_run_id: model_run.id,
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
