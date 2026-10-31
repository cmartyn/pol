# What just moved: the line under a race page's figure.
#
# It uses the dashboard's own definition of a move, Site::Movers' window
# (site.movers_window_days) and noise floor (site.movers_floor_pp). A race the
# dashboard lists as a mover never reads as steady on its own page, and
# run-to-run simulation noise never reads as movement.
#
# Walking back from the newest run, the comparison is the most recent run
# whose leading side sat at least the floor away from where it stands now:
# the last time the forecast was meaningfully different. The walk stops at
# the window's edge and at the newest data correction, because a jump across
# a correction is the repair the chart labels, not voters moving.
#
# Pure: points in, a Result out. The words are RacesHelper#forecast_change_line's.
module Site
  class ForecastChange
    # probabilities: { "dem" => 0.48, "rep" => 0.52, "other" => 0.0 }
    Point = Struct.new(:time, :probabilities, keyword_init: true)

    # kind
    #   :up, :down  the leader's chance was `probability` at `time`
    #   :flipped    `party` led at `time`, with `probability`
    #   :steady     the leader's chance stayed within low..high since `time`;
    #               `since` says what `time` is (:window, :first_run, :correction)
    #   :corrected  the newest run is the first since a data correction at `time`
    Result = Struct.new(:kind, :party, :probability, :time, :low, :high, :since, keyword_init: true)

    def self.call(points, corrections: [])
      new(points, corrections: corrections).call
    end

    def initialize(points, corrections: [],
                   window_days: Pol::Params.fetch!(:site, :movers_window_days),
                   floor_pp: Pol::Params.fetch!(:site, :movers_floor_pp))
      @points = points
      @corrections = corrections
      @window = window_days.days
      @floor = floor_pp / 100.0
    end

    # nil when there is nothing to compare: fewer than two runs, or no other
    # run inside the window.
    def call
      return nil if @points.size < 2

      latest = @points.last
      party = leader(latest)
      now = latest.probabilities.fetch(party)
      start, since = comparison_start(latest)
      earlier = @points[0...-1].select { |point| point.time >= start }

      if earlier.empty?
        return since == :correction ? Result.new(kind: :corrected, party: party, time: start) : nil
      end

      moved = earlier.reverse.find { |point| (point.probabilities.fetch(party) - now).abs >= @floor }
      return moved_from(moved, party, now) if moved

      values = (earlier + [ latest ]).map { |point| point.probabilities.fetch(party) }
      Result.new(kind: :steady, party: party, low: values.min, high: values.max, time: start, since: since)
    end

    private
      def moved_from(point, party, now)
        then_party = leader(point)
        if then_party == party
          before = point.probabilities.fetch(party)
          Result.new(kind: before > now ? :down : :up, party: party, probability: before, time: point.time)
        else
          Result.new(kind: :flipped, party: then_party, probability: point.probabilities.fetch(then_party), time: point.time)
        end
      end

      # Where the comparison may reach back to, and why it stops there. A
      # correction's time is the first run after it, which is already on the
      # new inputs and so comparable with the latest.
      def comparison_start(latest)
        window_start = latest.time - @window
        correction = @corrections.select { |time| time > window_start && time <= latest.time }.max

        if correction
          [ correction, :correction ]
        elsif @points.first.time > window_start
          [ @points.first.time, :first_run ]
        else
          [ window_start, :window ]
        end
      end

      def leader(point)
        Site::Format.leader(
          p_dem_win: point.probabilities.fetch("dem"),
          p_rep_win: point.probabilities.fetch("rep"),
          p_other_win: point.probabilities.fetch("other", 0.0)
        ).first
      end
  end
end
