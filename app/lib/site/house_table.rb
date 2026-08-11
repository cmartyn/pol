# The /house table: all 435 districts with their baseline, latest forecast
# and district poll count. Three bulk queries total — races (no candidates
# preload needed: every modelled House race runs on generic dem/rep sides,
# Forecast::RaceModel#side_a/#side_b fall back to the party itself when no
# candidate is seeded, so Site::RaceSides never has to look at a House
# race's candidates), latest forecasts, and one grouped poll count — and none
# of the three scales with row count, so this is exactly as many queries at
# 435 districts as at 4. Search/filter is client-side (Stimulus), so this one
# query set serves every search state.
module Site
  class HouseTable
    Row = Struct.new(:race, :forecast, :poll_count, keyword_init: true)

    def self.build
      new.build
    end

    def build
      races = Race.house.order(:state, :district).to_a
      race_ids = races.map(&:id)
      forecasts = Forecast.latest_for_races.where(race_id: race_ids).index_by(&:race_id)
      poll_counts = Poll.where(race_id: race_ids).group(:race_id).count

      races.map do |race|
        Row.new(race: race, forecast: forecasts[race.id], poll_count: poll_counts[race.id].to_i)
      end
    end
  end
end
