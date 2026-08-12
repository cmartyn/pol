# The poll average: one weighted mean margin per race (or for the generic
# ballot), as of a given date. Margins are side A minus side B in percentage
# points, which for all but a handful of races is Democrat minus Republican.
#
# Every constant comes from `averaging:` in config/model_params.yml.
class Forecast::Averager
  # mean_margin is nil when nothing qualified — callers fall back to the
  # prior rather than pretending zero is an estimate. `weight` is W, the sum
  # of poll weights, which is what the blend saturates against and what lands
  # in forecasts.effective_poll_weight. `skipped_count` is the polls inside
  # the window that did not measure this matchup (see #measure).
  #
  # `reason` is set only when there were polls and we declined to average them
  # anyway; `matchups` carries the contests they disagreed about, so a page can
  # say which ones rather than "something was wrong".
  Result = Struct.new(:mean_margin, :weight, :poll_count, :window_days, :skipped_count,
                      :reason, :matchups, keyword_init: true) do
    # "Polled" means there is an average to blend, not merely that rows exist.
    # Polls whose weights sum to zero leave the race on its prior — and this is
    # what keeps the blend from ever multiplying by a nil mean.
    def polled?
      !mean_margin.nil?
    end
  end

  # One poll reduced to the number the average cares about. `adjustment` is
  # the pollster house effect that was removed from it (0.0 when none was),
  # kept alongside the margin so a caller can say what it did rather than
  # only what came out.
  Measurement = Struct.new(:poll, :margin, :adjustment, keyword_init: true)

  # `house_effects` is { pollster_id => effect }, in percentage points of
  # D−R margin, and only ever holds effects a run decided to apply — see
  # Forecast::HouseEffects. Defaulting it to empty is what keeps every caller
  # that does not know about house effects (and every Phase 3 golden) reading
  # exactly the numbers it read before.
  def initialize(as_of:, house_effects: {})
    @as_of = as_of.to_date
    @house_effects = house_effects || {}
    @window_days = Pol::Params.fetch!(:averaging, :window_days)
    @extended_window_days = Pol::Params.fetch!(:averaging, :extended_window_days)
    @min_polls_in_window = Pol::Params.fetch!(:averaging, :min_polls_in_window)
    @half_life_days = Pol::Params.fetch!(:averaging, :half_life_days).to_f
    @default_sample_size = Pol::Params.fetch!(:averaging, :default_sample_size)
    @sample_size_cap = Pol::Params.fetch!(:averaging, :sample_size_cap)
    @sample_size_pivot = Pol::Params.fetch!(:averaging, :sample_size_pivot).to_f
  end

  attr_reader :as_of, :house_effects

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
    window = @extended_window_days if within(measured, @window_days).size < @min_polls_in_window

    in_window = within(measured, window)
    skipped = in_hand.count { |poll| age_days(poll) <= window } - in_window.size

    # Every race, not only House districts. A Senate race whose nomination is
    # unsettled has several same-party candidates seeded, so several
    # hypothetical matchups satisfy the parser's candidate check and all of
    # them are ingested — the same contamination a district has, arrived at by
    # a different route. Phase 9 estimates pollster house effects from
    # race-level residuals, so a blended average here would end up inside every
    # pollster's estimated lean.
    #
    # The test runs on everything inside the window and *before* the
    # one-per-pollster cut, which is the order that matters. Running it after
    # would let an id tiebreak among a pollster's same-day rows decide which
    # hypothetical the site publishes: Public Policy Polling fielded seven
    # South Carolina rows to 2026-07-17, against seven different Republicans,
    # and the cut keeps whichever landed with the highest id. A pollster
    # testing seven opponents in one field period is itself the evidence that
    # nobody knows who is running — that is a race to stand down on, not one
    # to pick a winner from by insertion order.
    #
    # Ageing out still works, because the window is what does it: a race whose
    # old hypotheticals have fallen out of the window has resolved itself, and
    # no hand-editing is owed as each primary settles.
    #
    # The generic ballot is untouched: its columns name nobody, so its polls
    # carry no matchup and this can never fire on them.
    matchups = contested_pairs(in_window, side_a, side_b)
    if matchups.size > 1
      return Result.new(
        mean_margin: nil, weight: 0.0, poll_count: in_window.size, window_days: window,
        skipped_count: skipped, reason: :ambiguous_matchup, matchups: matchups
      )
    end

    # One poll per pollster goes on doing its own job — not letting one house
    # weigh twice — now that it is no longer also deciding the question above.
    kept = one_per_pollster(in_window)

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
    weight_at_age(age_days(poll), poll.sample_size)
  end

  # The same function on an age given explicitly, so Phase 9 can weigh a poll
  # by its distance from another poll's field date rather than from as_of.
  # Callers there pass an absolute distance: a poll fielded a week after the
  # one being scored must not weigh more than one fielded on the day, which is
  # what exp(-ln2 × negative_age / half_life) would do.
  def weight_at_age(age_days, sample_size)
    recency = Math.exp(-Math.log(2) * age_days / @half_life_days)
    # A recorded sample size of zero is an unknown sample size, not a poll of
    # nobody. The scraper already normalises those to nil; manual and CSV entry
    # can still get there, and a zero would otherwise weigh the poll out of
    # existence rather than fall back to the default.
    size = sample_size
    size = @default_sample_size unless size&.positive?
    recency * Math.sqrt([ size, @sample_size_cap ].min / @sample_size_pivot)
  end

  def age_days(poll)
    (as_of - poll.field_end).to_i
  end

  # The two eligibility rules below are public for one reason: Forecast::
  # HouseEffects has to apply exactly the same ones. A residual measured from
  # a poll this class would refuse — a placeholder opponent, a missing side,
  # a race whose polls disagree about who is running — would carry that
  # contamination into every pollster's estimated lean, and from there into
  # every average. Sharing the code is what stops the two drifting apart.

  # One poll reduced to the margin the average would read from it, or nil
  # when the poll does not measure this matchup at all.
  def measurement(poll, side_a: :dem, side_b: :rep)
    measure(poll, side_a, side_b)
  end

  # ["andrews vs norman", "andrews vs sanford"] — the distinct contests these
  # measurements named on the two sides being compared. More than one and
  # there is no single contest to average.
  def distinct_matchups(measurements, side_a: :dem, side_b: :rep)
    contested_pairs(measurements, side_a, side_b)
  end

  private
    # ["achilles vs risch"] — the distinct contests these polls measured,
    # named on the two sides being compared and nobody else. Montana's
    # two-way and three-way Bankhead-vs-Alme tables are one contest with a
    # third option offered, and this is what says so; Maine's four Democrats
    # against LePage are four contests, and this says that too. Polls whose
    # key does not name both sides are left out rather than counted as their
    # own contest — the key is provenance, and a poll without it is not
    # evidence that the race is ambiguous.
    def contested_pairs(measurements, side_a, side_b)
      measurements.filter_map { |measurement|
        by_party = Ingest::Matchup.parse(measurement.poll.matchup_key)
        a = by_party[side_a.to_s]
        b = by_party[side_b.to_s]
        "#{a} vs #{b}" if a && b
      }.uniq.sort
    end

    # Top result for each side, so a poll listing two Democrats scores the
    # stronger one. A poll that never asked about one of the two sides is not
    # evidence about this matchup and returns nil.
    def measure(poll, side_a, side_b)
      # A poll fought against "Generic Republican" measured the party, not the
      # nominee, and its margin is not a reading of this contest. The parser
      # refuses those tables now; four rows predate the guard and are still in
      # the corpus, so they are dropped here — counted in skipped_count, which
      # is exactly what it means, and still shown on the race page.
      return nil if Ingest::Matchup.placeholder_opponent?(poll)

      a = top_pct(poll, side_a)
      b = top_pct(poll, side_b)
      return nil if a.nil? || b.nil?

      # A positive house effect means this pollster's polls run more
      # Democratic than the field, so subtracting it removes the lean. The
      # lookup only ever holds effects the run decided to apply, which is why
      # there is no threshold test here.
      adjustment = @house_effects[poll.pollster_id].to_f
      Measurement.new(poll: poll, margin: a - b - adjustment, adjustment: adjustment)
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
