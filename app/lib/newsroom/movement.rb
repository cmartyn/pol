module Newsroom
  # Which races moved enough to be worth writing about, comparing the run that
  # just finished against the succeeded run closest to site.movers_window_days
  # before it — the same comparison the dashboard's movers module makes
  # (ModelRun.comparison_run), so the newsroom never writes up movement the
  # site isn't showing, or vice versa.
  #
  # The threshold here is newsroom.movement_threshold, a fraction of win
  # probability (0.08 = eight points), and it is deliberately far above the
  # dashboard's noise floor of 1.5 points: the dashboard can afford to show a
  # small shift in a table, but a whole piece of prose about one needs the
  # movement to be real.
  class Movement
    Moved = Struct.new(:race, :delta, keyword_init: true) do
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
      def moved_races(previous)
        latest_forecasts = Forecast.where(model_run_id: model_run.id).index_by(&:race_id)
        previous_forecasts = Forecast.where(model_run_id: previous.id).index_by(&:race_id)
        common_race_ids = latest_forecasts.keys & previous_forecasts.keys
        return [] if common_race_ids.empty?

        races = Race.where(id: common_race_ids).includes(:candidates).index_by(&:id)

        common_race_ids.filter_map { |race_id|
          delta = latest_forecasts.fetch(race_id).p_dem_win - previous_forecasts.fetch(race_id).p_dem_win
          next if delta.abs.round(PROBABILITY_PLACES) < @threshold

          Moved.new(race: races.fetch(race_id), delta: delta)
        }.sort_by { |moved| -moved.delta.abs }
      end
  end
end
