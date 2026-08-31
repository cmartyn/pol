# The /senate table: every Senate race with its latest forecast, poll count
# and last poll date, sortable by column. Four bulk queries total (races +
# preloaded candidates, latest forecasts, and one aggregate poll query) no
# matter how many races there are — sorting happens in Ruby over the loaded
# rows, which is cheap at Senate scale (35 races) and doesn't add a query.
module Site
  class SenateTable
    Row = Struct.new(:race, :forecast, :poll_count, :last_poll_date, keyword_init: true)

    SORTS = %w[state rating probability margin lean polls last_poll].freeze
    DEFAULT_SORT = "state"

    def self.build(sort: nil, direction: "asc")
      new(sort: sort, direction: direction).build
    end

    def initialize(sort:, direction:)
      @sort = SORTS.include?(sort) ? sort : DEFAULT_SORT
      @direction = direction == "desc" ? "desc" : "asc"
    end

    attr_reader :sort, :direction

    def build
      races = Race.senate.includes(:candidates).to_a
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

      # Every branch returns a Comparable of the same shape across rows
      # (float, float, integer or a two-element array), and a missing
      # forecast sorts last regardless of direction — a nil forecast isn't
      # "low", it's unknown, but Ruby's sort needs *some* total order, and
      # putting it at one end beats a comparison error mid-sort.
      def sort_key(row)
        case sort
        when "rating", "probability"
          row.forecast ? leading_probability(row.forecast) : -1.0
        when "margin"
          row.forecast&.mean_margin || -Float::INFINITY
        when "lean"
          row.race.lean || -Float::INFINITY
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
