module Newsroom
  # Which races moved enough to be worth writing about, comparing the run that
  # just finished against the succeeded run closest to site.movers_window_days
  # before it — the same comparison the dashboard's movers module makes
  # (ModelRun.comparison_run), so the newsroom never writes up movement the
  # site isn't showing.
  #
  # With one exception: a race the newsroom has already written a movement
  # note about since that comparison run is measured from the run the note was
  # written from. The reader has been told about everything before it, and the
  # cooldown between notes shortens toward election day (Newsroom::Caps
  # .movement_cooldown_days) — against a fixed seven-day window, a short
  # cooldown would re-tell the same move every run until it slid out of the
  # window. The dashboard shows the week's movers; the newsroom writes about
  # what is new since it last spoke.
  #
  # The threshold here is newsroom.movement_threshold, a fraction of win
  # probability (0.08 = eight points), and it is deliberately far above the
  # dashboard's noise floor of 1.5 points: the dashboard can afford to show a
  # small shift in a table, but a whole piece of prose about one needs the
  # movement to be real.
  class Movement
    # baseline_run is the run the delta is measured from: the comparison run,
    # or this race's latest note's run (see above).
    Moved = Struct.new(:race, :delta, :baseline_run, keyword_init: true) do
      def delta_pp = delta * 100.0
    end

    Comparison = Struct.new(:previous_run, :races, keyword_init: true)

    # Win probabilities are simulated counts over simulation.n_sims draws, so
    # at 10,000 sims they carry four decimal places of real resolution and no
    # more. Rounding the difference to that resolution before comparing keeps
    # the threshold meaning what it says: 0.62 − 0.54 is 0.07999999999999996
    # in binary floating point, and a race that moved exactly eight points
    # should be a mover rather than a rounding accident.
    PROBABILITY_PLACES = 4

    def self.call(...)
      new(...).call
    end

    def initialize(model_run:)
      @model_run = model_run
      @window_days = Pol::Params.fetch!(:site, :movers_window_days)
      @threshold = Pol::Params.fetch!(:newsroom, :movement_threshold)
    end

    attr_reader :model_run

    # nil when there is nothing to compare against yet. Otherwise a Comparison
    # whose races are ordered biggest move first, so that if the daily cap runs
    # out mid-list it is the smallest movers that go unwritten.
    def call
      previous = ModelRun.comparison_run(model_run, window_days: @window_days)
      return nil unless previous

      Comparison.new(previous_run: previous, races: moved_races(previous))
    end

    private
      def moved_races(comparison)
        latest_forecasts = Forecast.excl_internals.where(model_run_id: model_run.id).index_by(&:race_id)
        return [] if latest_forecasts.empty?

        noted_runs = noted_runs_since(comparison, latest_forecasts.keys)
        baseline_forecasts = Forecast.excl_internals
                                     .where(model_run_id: [ comparison.id, *noted_runs.values.map(&:id) ].uniq)
                                     .index_by { |forecast| [ forecast.model_run_id, forecast.race_id ] }

        moved = latest_forecasts.filter_map { |race_id, latest|
          baseline_run, baseline = baseline_for(race_id, comparison, noted_runs, baseline_forecasts)
          next unless baseline

          delta = latest.p_dem_win - baseline.p_dem_win
          next if delta.abs.round(PROBABILITY_PLACES) < @threshold

          [ race_id, delta, baseline_run ]
        }
        return [] if moved.empty?

        races = Race.where(id: moved.map(&:first)).includes(:candidates).index_by(&:id)
        moved.map { |race_id, delta, baseline_run|
          Moved.new(race: races.fetch(race_id), delta: delta, baseline_run: baseline_run)
        }.sort_by { |item| -item.delta.abs }
      end

      # [run, forecast] the race is measured from: the run its latest note was
      # written from when that run carries a forecast for the race, else the
      # comparison run. The forecast is nil when neither run has one — a race
      # the runs do not share is skipped rather than treated as movement.
      def baseline_for(race_id, comparison, noted_runs, forecasts)
        noted = noted_runs[race_id]
        if noted && (forecast = forecasts[[ noted.id, race_id ]])
          return [ noted, forecast ]
        end

        [ comparison, forecasts[[ comparison.id, race_id ]] ]
      end

      # race_id => the run the race's most recent movement note was written
      # from, for notes written from a run no earlier than the comparison run.
      #
      # Retracted notes count, as they do for the cooldown (Newsroom::Caps):
      # the editor pulled the piece, and the newsroom must not regenerate it.
      # A note with no run recorded is not here — it cannot be measured from,
      # and the time cooldown is what keeps its race quiet.
      def noted_runs_since(comparison, race_ids)
        noted = Dispatch.movement_note.where(race_id: race_ids).where.not(model_run_id: nil)
                        .pluck(:race_id, :model_run_id)
        runs = ModelRun.where(id: noted.map(&:last).uniq)
                       .where(started_at: comparison.started_at..)
                       .index_by(&:id)

        noted.group_by(&:first).transform_values { |pairs|
          pairs.filter_map { |_race_id, run_id| runs[run_id] }.max_by(&:started_at)
        }.compact
      end
  end
end
