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
# The payload carries the words, the JS carries the geometry: every
# human-readable string the chart shows — margin labels, party letters, the
# field-period dateline, the sample description, the average annotation — is
# formatted here through Site::Format's unit-tested conventions, so the
# Stimulus controller only ever places prebuilt text and can never drift
# into a second implementation of "D+9.8"/"Even".
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

        average_margin = average.polled? ? average.mean_margin.round(2) : nil

        {
          side_a_party: side_a,
          side_b_party: side_b,
          # The letters the y-axis ticks wear ("D+10" / "I+5"), through the
          # same table Site::Format.margin letters with — the axis and the
          # dots' own labels cannot disagree about which letter a side is.
          side_a_letter: Site::Format::PARTY_LETTER.fetch(side_a.to_s, "?"),
          side_b_letter: Site::Format::PARTY_LETTER.fetch(side_b.to_s, "?"),
          average_margin: average_margin,
          # The on-chart annotation for the reference line ("avg D+10.2") and
          # the party whose color it plots as — nil whenever there is no line
          # to annotate.
          average_label: average_margin && "avg #{Site::Format.margin(average_margin, side_a_party: side_a, side_b_party: side_b)}",
          average_party: average_margin && margin_party(average_margin, side_a, side_b),
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

          margin = (a - b).round(2)
          {
            t: poll.field_end.iso8601,
            margin: margin,
            margin_label: Site::Format.margin(margin, side_a_party: side_a, side_b_party: side_b),
            party: margin_party(margin, side_a, side_b),
            date_label: date_label(poll),
            pollster: poll.pollster.name,
            sponsor: poll.sponsor,
            source_url: poll.source_url,
            sample_size: poll.sample_size,
            sample_label: sample_label(poll),
            population: poll.population
          }
        end

        def top_pct(poll, party)
          poll.poll_results.filter_map { |result| result.pct if result.party == party.to_s }.max
        end

        # Which party a value's mark wears on the chart — mirrors
        # RacesHelper#margin_party: a margin that rounds to Even is "other"
        # (neutral slate), matching Site::Format.margin's own zero handling
        # rather than crediting whichever side owns the sign bit.
        def margin_party(value, side_a, side_b)
          rounded = value.round(1)
          return "other" if rounded.zero?

          rounded.positive? ? side_a : side_b
        end

        # The field period as the tooltip prints it, collapsed so shared
        # parts are said once: "Aug 6–9, 2026" within a month,
        # "Jul 29–Aug 1, 2026" across one, "Dec 28, 2025–Jan 2, 2026" across
        # a year. A poll with no recorded start — or a single field day —
        # is just its end date, the same rule the poll table's date column
        # applies (races/_poll_row.html.erb).
        def date_label(poll)
          start_date = poll.field_start
          end_date = poll.field_end
          return end_date.strftime("%b %-d, %Y") if start_date.nil? || start_date == end_date

          if start_date.year != end_date.year
            "#{start_date.strftime('%b %-d, %Y')}–#{end_date.strftime('%b %-d, %Y')}"
          elsif start_date.month != end_date.month
            "#{start_date.strftime('%b %-d')}–#{end_date.strftime('%b %-d, %Y')}"
          else
            "#{start_date.strftime('%b %-d')}–#{end_date.strftime('%-d, %Y')}"
          end
        end

        # "812 LV" — delimited count plus the population screened for, or the
        # bare count when the source never said which ("unknown" is a
        # database default, not a word to print). nil when the sample size
        # itself is unknown, so the tooltip drops the row entirely.
        def sample_label(poll)
          return nil if poll.sample_size.nil?

          count = ActiveSupport::NumberHelper.number_to_delimited(poll.sample_size)
          poll.population == "unknown" ? count : "#{count} #{poll.population.upcase}"
        end
    end
  end
end
