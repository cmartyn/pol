# The dashboard's "Movers" module: the races whose Democratic win probability
# moved the most between the latest succeeded model run and the succeeded run
# closest to `site.movers_window_days` days before it. Below
# `site.movers_floor_pp` points of movement a shift is Monte Carlo noise, not
# news (docs/BUILD_NOTES.md Phase 3 §8.2 measured ~1.4pp of run-to-run noise
# on the Senate control probability at n_sims=10,000) — such races are
# dropped rather than shown as false movement.
#
# Three bulk queries total, none of them scaling with the number of races:
# the two model runs (ModelRun.comparison_run, which the newsroom's movement
# notes also use, so both answer "last week" the same way), and one Forecast
# query per run.
module Site
  class Movers
    Mover = Struct.new(:race, :delta_pp, :latest_p_dem_win, :previous_p_dem_win, keyword_init: true) do
      def direction
        delta_pp.positive? ? :dem : :rep
      end
    end

    def self.call(as_of: Time.current)
      new(as_of: as_of).call
    end

    def initialize(as_of: Time.current)
      @as_of = as_of
      @window_days = Pol::Params.fetch!(:site, :movers_window_days)
      @floor_pp = Pol::Params.fetch!(:site, :movers_floor_pp)
      @count = Pol::Params.fetch!(:site, :movers_count)
    end

    # nil when there isn't enough history to compare (fewer than two
    # succeeded runs) or nothing clears the floor — callers read nil as "omit
    # the section", per the brief.
    def call
      latest = ModelRun.succeeded.latest.first
      return nil unless latest

      previous = comparison_run(latest)
      return nil unless previous

      movers = build_movers(latest, previous)
      movers.presence
    end

    private
      def comparison_run(latest)
        ModelRun.comparison_run(latest, window_days: @window_days)
      end

      def build_movers(latest, previous)
        latest_forecasts = Forecast.excl_internals.where(model_run_id: latest.id).index_by(&:race_id)
        previous_forecasts = Forecast.excl_internals.where(model_run_id: previous.id).index_by(&:race_id)
        common_race_ids = latest_forecasts.keys & previous_forecasts.keys
        return [] if common_race_ids.empty?

        races = Race.where(id: common_race_ids).index_by(&:id)

        movers = common_race_ids.filter_map do |race_id|
          latest_p = latest_forecasts.fetch(race_id).p_dem_win
          previous_p = previous_forecasts.fetch(race_id).p_dem_win
          delta_pp = (latest_p - previous_p) * 100.0
          next if delta_pp.abs < @floor_pp

          Mover.new(race: races.fetch(race_id), delta_pp: delta_pp,
                    latest_p_dem_win: latest_p, previous_p_dem_win: previous_p)
        end

        movers.sort_by { |mover| -mover.delta_pp.abs }.first(@count)
      end
  end
end
