# The polls-over-time scatter payload for a race page: every poll of the
# race plotted at (field_end, margin), plus the *current* weighted average as
# a reference line.
#
# The reference line is computed live via Forecast::Averager, not read off
# the race's stored forecast — a forecast's mean_margin is the simulator's
# output (prior blended with the average, then Monte Carlo noise), which is
# a different number from the poll average by design. Showing the poll
# average here and the model's estimate on the forecast-detail section keeps
# the two honestly distinct. This does not re-simulate anything; it reuses
# the same averaging Forecast::RaceModel uses (Forecast::Averager is
# explicitly reusable for this per the brief).
#
# Returns nil when the race has no polls at all — the brief wants this chart
# to omit itself gracefully rather than render an empty axes box.
module Site
  module Charts
    class PollsScatter
      def self.build(race:, polls:, as_of: Time.current, house_effects: {})
        new(race: race, polls: polls, as_of: as_of, house_effects: house_effects).build
      end

      # polls: an array (or loaded relation) of Poll, with poll_results and
      # pollster preloaded by the caller — this never queries beyond the one
      # Averager#for_race call, which reuses the same preloaded array.
      #
      # house_effects: the adjustments the run on show applied. The reference
      # line has to be drawn from the adjusted average, because that is the
      # average the model used; drawing the unadjusted one would put a line
      # on the page that no number elsewhere on the site agrees with. The
      # plotted points stay raw — they are what the pollster published, and
      # the poll table beneath shows each one's adjustment alongside it.
      def initialize(race:, polls:, as_of:, house_effects: {})
        @race = race
        @polls = polls.to_a
        @as_of = as_of
        @house_effects = house_effects || {}
      end

      def build
        return nil if @polls.empty?

        side_a, side_b = Site::RaceSides.for(@race.candidates)
        average = Forecast::Averager.new(as_of: @as_of, house_effects: @house_effects).for_race(
          @race, side_a: side_a.to_sym, side_b: side_b.to_sym, polls: @polls
        )
        points = @polls.filter_map { |poll| point(poll, side_a, side_b) }
        return nil if points.empty?

        {
          side_a_party: side_a,
          side_b_party: side_b,
          average_margin: average.polled? ? average.mean_margin.round(2) : nil,
          # Why there is no reference line, when there are points to draw one
          # through. Today the only reason is :ambiguous_matchup — the polls
          # that qualified disagree about who is running — and the page says
          # so rather than leaving a reader to wonder.
          average_reason: average.reason,
          matchups: average.matchups,
          points: points
        }
      end

      private
        def point(poll, side_a, side_b)
          a = top_pct(poll, side_a)
          b = top_pct(poll, side_b)
          return nil if a.nil? || b.nil?

          {
            t: poll.field_end.iso8601,
            margin: (a - b).round(2),
            pollster: poll.pollster.name,
            source_url: poll.source_url,
            sample_size: poll.sample_size,
            population: poll.population
          }
        end

        def top_pct(poll, party)
          poll.poll_results.filter_map { |result| result.pct if result.party == party.to_s }.max
        end
    end
  end
end
