# The /house table: all 435 districts with their baseline, latest forecast,
# district poll count and last poll date, sortable by column. Three bulk
# queries total — races (no candidates preload needed: every modelled House
# race runs on generic dem/rep sides, Forecast::RaceModel#side_a/#side_b fall
# back to the party itself when no candidate is seeded, so Site::RaceSides
# never has to look at a House race's candidates), latest forecasts, and one
# aggregate poll query — and none of the three scales with row count, so this
# is exactly as many queries at 435 districts as at 4. Sorting happens in Ruby
# over the loaded rows, so a different sort costs no extra query. Search is
# client-side (Stimulus), so this one query set serves every search state.
#
# Deliberately a sibling of Site::SenateTable rather than a shared base class:
# the two chambers are expected to diverge on which columns they carry, and
# two readable classes that happen to rhyme beat one class carrying a chamber
# flag. What IS shared lives in the view layer (the search box partial, the
# sort_header helper) where it is genuinely chamber-agnostic.
module Site
  class HouseTable
    Row = Struct.new(:race, :forecast, :poll_count, :last_poll_date, keyword_init: true)

    SORTS = %w[state rating probability margin baseline polls last_poll].freeze
    DEFAULT_SORT = "state"

    def self.build(sort: nil, direction: "asc")
      new(sort: sort, direction: direction).build
    end

    def initialize(sort: nil, direction: "asc")
      @sort = SORTS.include?(sort) ? sort : DEFAULT_SORT
      @direction = direction == "desc" ? "desc" : "asc"
    end

    attr_reader :sort, :direction

    def build
      races = Race.house.order(:state, :district).to_a
      race_ids = races.map(&:id)
      forecasts = Forecast.latest_for_races.where(race_id: race_ids).index_by(&:race_id)
      poll_stats = Poll.model_corpus.where(race_id: race_ids)
        .group(:race_id)
        .select(:race_id, "COUNT(*) AS poll_count", "MAX(field_end) AS last_poll_date")
        .index_by(&:race_id)

      rows = races.map do |race|
        stats = poll_stats[race.id]
        Row.new(
          race: race,
          forecast: forecasts[race.id],
          poll_count: stats ? stats.poll_count.to_i : 0,
          last_poll_date: stats&.last_poll_date
        )
      end

      sort_rows(rows)
    end

    private
      def sort_rows(rows)
        sorted = rows.sort_by { |row| sort_key(row) }
        sorted.reverse! if direction == "desc"
        sorted
      end

      # Same contract as Site::SenateTable#sort_key: every branch returns a
      # Comparable of one shape across all rows, and a missing value sorts to
      # one end rather than raising mid-sort. Unlike the Senate, a House
      # district can legitimately have no baseline at all, so that gets the
      # same treatment as a missing forecast.
      def sort_key(row)
        case sort
        when "rating", "probability"
          row.forecast ? leading_probability(row.forecast) : -1.0
        when "margin"
          row.forecast&.mean_margin || -Float::INFINITY
        when "baseline"
          row.race.baseline_margin || -Float::INFINITY
        when "polls"
          row.poll_count
        when "last_poll"
          row.last_poll_date || Date.new(1970, 1, 1)
        else
          [ row.race.state, row.race.district.to_i ]
        end
      end

      def leading_probability(forecast)
        [ forecast.p_dem_win, forecast.p_rep_win, forecast.p_other_win ].max
      end
  end
end
