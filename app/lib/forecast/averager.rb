# The poll average: one weighted mean margin per race (or for the generic
# ballot), as of a given date. Margins are side A minus side B in percentage
# points, which for all but a handful of races is Democrat minus Republican.
#
# Every constant comes from `averaging:` in config/model_params.yml.
class Forecast::Averager
  # Fewer than this many usable polls inside the narrow window and the window
  # widens to averaging.extended_window_days.
  MIN_POLLS_IN_WINDOW = 2

  # mean_margin is nil when nothing qualified — callers fall back to the
  # prior rather than pretending zero is an estimate. `weight` is W, the sum
  # of poll weights, which is what the blend saturates against and what lands
  # in forecasts.effective_poll_weight. `skipped_count` is the polls inside
  # the window that did not measure this matchup (see #measure).
  Result = Struct.new(:mean_margin, :weight, :poll_count, :window_days, :skipped_count, keyword_init: true) do
    # "Polled" means there is an average to blend, not merely that rows exist.
    # Polls whose weights sum to zero leave the race on its prior — and this is
    # what keeps the blend from ever multiplying by a nil mean.
    def polled?
      !mean_margin.nil?
    end
  end

  # One poll reduced to the number the average cares about.
  Measurement = Struct.new(:poll, :margin, keyword_init: true)

  def initialize(as_of:)
    @as_of = as_of.to_date
    @window_days = Pol::Params.fetch!(:averaging, :window_days)
    @extended_window_days = Pol::Params.fetch!(:averaging, :extended_window_days)
    @half_life_days = Pol::Params.fetch!(:averaging, :half_life_days).to_f
    @default_sample_size = Pol::Params.fetch!(:averaging, :default_sample_size)
    @sample_size_cap = Pol::Params.fetch!(:averaging, :sample_size_cap)
    @sample_size_pivot = Pol::Params.fetch!(:averaging, :sample_size_pivot).to_f
  end

  attr_reader :as_of

  # `polls` may be a relation or a plain array; callers that are about to
  # average hundreds of races should preload poll_results and pass arrays.
  def for_race(race, side_a: :dem, side_b: :rep, polls: nil)
    call(polls: polls || race.polls.includes(:poll_results), side_a: side_a, side_b: side_b)
  end

  # The national environment: the same machinery over generic-ballot polls,
  # whose results carry a party but no candidate.
  def for_generic_ballot(polls: nil)
    call(polls: polls || Poll.for_generic_ballot.includes(:poll_results))
  end

  def call(polls:, side_a: :dem, side_b: :rep)
    raise ArgumentError, "side_a and side_b must differ (both #{side_a})" if side_a.to_s == side_b.to_s

    # A poll fielded after the as-of date does not exist yet as far as this
    # average is concerned; back-dated runs have to reproduce what the model
    # would have said at the time.
    in_hand = polls.select { |poll| poll.field_end.present? && poll.field_end <= as_of }

    # Polls that do not measure the modelled matchup are dropped before
    # anything else, including the one-per-pollster cut. The brief lists the
    # window and the per-pollster rule first, but the live data settles the
    # order: Wikipedia pages publish several matchup tables per race, so
    # Tavern Research has four same-day Nebraska rows of which exactly one is
    # the Osborn-vs-Ricketts contest the model is forecasting. Deduplicating
    # first would keep whichever row happens to have the highest id and then
    # throw that pollster away for "missing a side". Filtering first keeps
    # the poll that actually measures the race. #skipped_count reports the
    # rest rather than hiding them.
    measured = in_hand.filter_map { |poll| measure(poll, side_a, side_b) }

    window = @window_days
    window = @extended_window_days if within(measured, @window_days).size < MIN_POLLS_IN_WINDOW

    kept = one_per_pollster(within(measured, window))
    skipped = in_hand.count { |poll| age_days(poll) <= window } - within(measured, window).size

    weight = 0.0
    weighted_sum = 0.0
    kept.each do |measurement|
      poll_weight = weight_for(measurement.poll)
      weight += poll_weight
      weighted_sum += poll_weight * measurement.margin
    end

    Result.new(
      mean_margin: weight.zero? ? nil : weighted_sum / weight,
      weight: weight,
      poll_count: kept.size,
      window_days: window,
      skipped_count: skipped
    )
  end

  # exp(-ln2 × age / half_life) × sqrt(min(n, cap) / pivot). A poll with the
  # pivot sample size and no age weighs exactly 1.
  def weight_for(poll)
    recency = Math.exp(-Math.log(2) * age_days(poll) / @half_life_days)
    # A recorded sample size of zero is an unknown sample size, not a poll of
    # nobody. The scraper already normalises those to nil; manual and CSV entry
    # can still get there, and a zero would otherwise weigh the poll out of
    # existence rather than fall back to the default.
    size = poll.sample_size
    size = @default_sample_size unless size&.positive?
    recency * Math.sqrt([ size, @sample_size_cap ].min / @sample_size_pivot)
  end

  def age_days(poll)
    (as_of - poll.field_end).to_i
  end

  private
    # Top result for each side, so a poll listing two Democrats scores the
    # stronger one. A poll that never asked about one of the two sides is not
    # evidence about this matchup and returns nil.
    def measure(poll, side_a, side_b)
      a = top_pct(poll, side_a)
      b = top_pct(poll, side_b)
      return nil if a.nil? || b.nil?

      Measurement.new(poll: poll, margin: a - b)
    end

    def top_pct(poll, party)
      poll.poll_results.filter_map { |result| result.pct if result.party == party.to_s }.max
    end

    def within(measurements, window)
      measurements.select { |measurement| age_days(measurement.poll) <= window }
    end

    # One poll per pollster: the latest by field_end, then by field_start
    # (a poll with no field_start is treated as a single-day poll), then by
    # id so the choice is never arbitrary. Sorted by id at the end so the
    # floating-point sum is reproducible whatever order the caller passed.
    def one_per_pollster(measurements)
      measurements
        .group_by { |measurement| measurement.poll.pollster_id }
        .values
        .map { |group| group.max_by { |m| [ m.poll.field_end, m.poll.field_start || m.poll.field_end, m.poll.id ] } }
        .sort_by { |measurement| measurement.poll.id }
    end
end
