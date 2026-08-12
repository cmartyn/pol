# The Monte Carlo. Every simulated world draws error at four levels and adds
# them up:
#
#   margin = mu + N + D[division] + S[state] + idiosyncratic
#
# N is one national error shared by every race in both chambers; D is one per
# census division, shared by every race in it; S is one per state, read by that
# state's Senate race AND by every one of its House districts; the last term is
# the race's own. All four are scaled by the same time multiplier.
#
# The shared terms are the whole point. Independent noise averages away over
# 435 districts and a chamber forecast built on it is falsely precise;
# correlated error does not average away, which is why it — not the size of any
# one race's uncertainty — is what decides how wide a seat distribution is.
# Phase 10 replaced a single national term with this structure, and the state
# term is the structural gain: a bad night in Georgia is now a bad night for
# Georgia's Senate race and its districts together.
#
# Margins are side A minus side B in percentage points. Given the same seed and
# the same entries in the same order, every number this produces is identical.
class Forecast::Simulator
  # What the simulator needs to know about a race; no ActiveRecord below this
  # line. `sigma` is the election-day-equivalent standard deviation of the
  # race's OWN error — the shared terms come from the params, and the time
  # multiplier is applied here, once, to all four. `state` is the two-letter
  # code, which is how a race finds its state and division draws. `certain` is
  # a Side when the race has only one possible winner.
  Entry = Struct.new(:race_id, :chamber, :state, :mu, :sigma, :weight, :side_a, :side_b, :certain,
                     keyword_init: true)

  RaceOutcome = Struct.new(
    :race_id, :p_dem_win, :p_rep_win, :p_other_win, :mean_margin, :percentiles, :weight,
    keyword_init: true
  )

  ChamberOutcome = Struct.new(
    :chamber, :p_dem_control, :p_rep_control, :mean_dem_seats, :seat_histogram,
    keyword_init: true
  )

  Result = Struct.new(:races, :chambers, :n_sims, :time_multiplier, :seed, keyword_init: true)

  # The three shared error series a race reads: `national` is one array of
  # n_sims draws; `by_division` and `by_state` are one such array apiece,
  # keyed by division name and two-letter state code.
  SharedErrors = Struct.new(:national, :by_division, :by_state)

  PERCENTILES = [ 5, 25, 50, 75, 95 ].freeze
  CHAMBERS = %i[senate house].freeze
  CAUCUSES = %i[dem rep uncommitted].freeze

  # Per-chamber seat counting. `buckets` holds one running count per simulated
  # world; `fixed` holds the seats that are not in doubt at all, which cost one
  # addition rather than n_sims of them.
  class Tally
    attr_reader :buckets, :fixed

    def initialize(n_sims)
      @buckets = CAUCUSES.index_with { Array.new(n_sims, 0) }
      @fixed = CAUCUSES.index_with { 0 }
    end

    def total(caucus, index)
      @fixed[caucus] + @buckets[caucus][index]
    end
  end

  def initialize(entries:, seed:, as_of:, n_sims: nil)
    @entries = entries
    @seed = seed
    @as_of = as_of.to_date
    @n_sims = n_sims || Pol::Params.fetch!(:simulation, :n_sims)
  end

  attr_reader :entries, :seed, :as_of, :n_sims

  # t = min(cap, 1 + days_to_election / scale): a forecast three months out is
  # wider than one made on the eve of the election. Floored at election day so
  # a back-dated or late run cannot shrink the error below its election-day
  # value (or, past the election, invert it).
  def time_multiplier
    days = [ (Pol::Params.fetch!(:election, :date).to_date - as_of).to_i, 0 ].max
    [ Pol::Params.fetch!(:error_model, :time_mult_cap),
      1.0 + (days / Pol::Params.fetch!(:error_model, :time_scale_days).to_f) ].min
  end

  def call
    multiplier = time_multiplier
    gaussian = Forecast::Gaussian.new(Random.new(seed))
    tallies = CHAMBERS.index_with { Tally.new(n_sims) }
    shared = shared_errors(gaussian, multiplier)

    races = entries.map do |entry|
      simulate(entry, shared: shared, gaussian: gaussian, multiplier: multiplier,
                      tally: tallies.fetch(entry.chamber))
    end

    Result.new(
      races: races,
      chambers: [ senate_outcome(tallies.fetch(:senate)), house_outcome(tallies.fetch(:house)) ],
      n_sims: n_sims,
      time_multiplier: multiplier,
      seed: seed
    )
  end

  private
    # One national series, one per census division, one per state. Each is
    # n_sims long and is read — not redrawn — by every race that belongs to it,
    # which is both what makes the correlation real and what keeps the cost at
    # 9 + 50 series rather than three extra draws per race per world.
    #
    # Only states with a race still in doubt are drawn for: an uncontested race
    # takes no noise at all, so it neither needs a state series nor may be
    # allowed to conjure one — that would shift every draw after it and move
    # every other race's numbers. Divisions and states are drawn in a fixed
    # canonical order — Census order for divisions, alphabetical for states —
    # rather than in the order the entries happen to arrive, so that adding a
    # race in a state already on the board leaves every shared series untouched.
    def shared_errors(gaussian, multiplier)
      states = entries.reject(&:certain).map { |entry| state_of(entry) }.uniq
      divisions = states.map { |state| Pol::CensusDivisions.for(state) }.uniq

      SharedErrors.new(
        series(gaussian, :sigma_national, multiplier),
        Pol::CensusDivisions.names.select { |name| divisions.include?(name) }
                            .index_with { series(gaussian, :sigma_regional, multiplier) },
        states.sort.index_with { series(gaussian, :sigma_state, multiplier) }
      )
    end

    def series(gaussian, key, multiplier)
      sigma = Pol::Params.fetch!(:error_model, key) * multiplier

      Array.new(n_sims) { gaussian.next * sigma }
    end

    # A race with no state could take neither a state nor a regional error, and
    # would sit in the seat total correlated to nothing but the national mood —
    # narrowing the distribution exactly where this phase widened it. Refused
    # rather than defaulted.
    def state_of(entry)
      return entry.state if entry.state.present?

      raise ArgumentError, "Forecast::Simulator: entry #{entry.race_id.inspect} has no state"
    end

    def simulate(entry, shared:, gaussian:, multiplier:, tally:)
      return certain_outcome(entry, tally) if entry.certain

      code = state_of(entry)
      state = shared.by_state.fetch(code)
      division = shared.by_division.fetch(Pol::CensusDivisions.for(code))
      national = shared.national
      sigma = entry.sigma * multiplier
      mu = entry.mu
      bucket_a = tally.buckets.fetch(entry.side_a.caucus)
      bucket_b = tally.buckets.fetch(entry.side_b.caucus)
      margins = Array.new(n_sims)
      total = 0.0
      side_a_wins = 0

      index = 0
      while index < n_sims
        # A margin of exactly zero goes to side A. It is a measure-zero event
        # on a continuous distribution; the rule exists so the code has no
        # undefined case, not because it will ever come up.
        margin = mu + national[index] + division[index] + state[index] + (gaussian.next * sigma)
        margins[index] = margin
        total += margin
        if margin >= 0.0
          side_a_wins += 1
          bucket_a[index] += 1
        else
          bucket_b[index] += 1
        end
        index += 1
      end

      margins.sort!
      probability_a = side_a_wins.to_f / n_sims

      RaceOutcome.new(
        race_id: entry.race_id,
        mean_margin: total / n_sims,
        percentiles: PERCENTILES.index_with { |p| percentile(margins, p) }.transform_keys(&:to_s),
        weight: entry.weight,
        **win_probabilities(entry.side_a, probability_a, entry.side_b, 1.0 - probability_a)
      )
    end

    # An uncontested race is not simulated: its winner is the same in every
    # world, so it contributes a fixed seat and takes no noise. The margin
    # estimate still stands — it is just not in doubt.
    def certain_outcome(entry, tally)
      tally.fixed[entry.certain.caucus] += 1

      RaceOutcome.new(
        race_id: entry.race_id,
        mean_margin: entry.mu,
        percentiles: PERCENTILES.index_with { entry.mu }.transform_keys(&:to_s),
        weight: entry.weight,
        **win_probabilities(entry.certain, 1.0, nil, 0.0)
      )
    end

    # p_dem_win is the probability a *Democratic-party* candidate wins, so an
    # independent's chances land in p_other_win however they intend to caucus.
    # Chamber control reads the caucus instead; the two are deliberately
    # different questions.
    def win_probabilities(side_a, probability_a, side_b, probability_b)
      probabilities = { p_dem_win: 0.0, p_rep_win: 0.0, p_other_win: 0.0 }
      probabilities[key_for(side_a)] += probability_a if side_a
      probabilities[key_for(side_b)] += probability_b if side_b
      probabilities
    end

    def key_for(side)
      case side.party
      when :dem then :p_dem_win
      when :rep then :p_rep_win
      else :p_other_win
      end
    end

    # Nearest-rank: the p-th percentile is the smallest value at or above which
    # p% of the draws sit. No interpolation, so the number is always one the
    # simulation actually produced.
    def percentile(sorted, percent)
      index = ((percent / 100.0) * sorted.size).ceil - 1
      sorted[index.clamp(0, sorted.size - 1)]
    end

    # Holdovers decide the Senate before a vote is counted: 34 Democratic-
    # caucusing and 31 Republican seats are not on the ballot. With a
    # Republican vice president, Republicans control at 50 and Democrats need
    # 51 — so a world where uncommitted independents hold the balance counts
    # for neither, and the two probabilities can sum to less than 1. That gap
    # is the forecast, not a rounding error.
    def senate_outcome(tally)
      dem_holdover = Pol::Params.fetch!(:chambers, :senate_holdover_dem_caucus)
      rep_holdover = Pol::Params.fetch!(:chambers, :senate_holdover_rep)
      vp_party = Pol::Params.fetch!(:chambers, :vp_party)
      # A tie is half the chamber; a majority without the tiebreak is one more.
      # The vice president's party controls at a tie, the other side needs the
      # majority — which is the whole content of the rule, and why neither
      # number is written down anywhere but here.
      tie = Pol::Params.fetch!(:chambers, :senate_total_seats) / 2
      majority = tie + 1
      dem_needs = vp_party == "dem" ? tie : majority
      rep_needs = vp_party == "rep" ? tie : majority

      dem_control = 0
      rep_control = 0
      dem_total = 0
      histogram = Hash.new(0)

      n_sims.times do |index|
        dem_seats = dem_holdover + tally.total(:dem, index)
        rep_seats = rep_holdover + tally.total(:rep, index)
        dem_control += 1 if dem_seats >= dem_needs
        rep_control += 1 if rep_seats >= rep_needs
        dem_total += dem_seats
        histogram[dem_seats] += 1
      end

      ChamberOutcome.new(
        chamber: :senate,
        p_dem_control: dem_control.to_f / n_sims,
        p_rep_control: rep_control.to_f / n_sims,
        mean_dem_seats: dem_total.to_f / n_sims,
        seat_histogram: histogram.sort.to_h.transform_keys(&:to_s)
      )
    end

    def house_outcome(tally)
      majority = Pol::Params.fetch!(:chambers, :house_majority_seats)
      dem_control = 0
      rep_control = 0
      dem_total = 0
      histogram = Hash.new(0)

      n_sims.times do |index|
        dem_seats = tally.total(:dem, index)
        dem_control += 1 if dem_seats >= majority
        rep_control += 1 if tally.total(:rep, index) >= majority
        dem_total += dem_seats
        histogram[dem_seats] += 1
      end

      ChamberOutcome.new(
        chamber: :house,
        p_dem_control: dem_control.to_f / n_sims,
        p_rep_control: rep_control.to_f / n_sims,
        mean_dem_seats: dem_total.to_f / n_sims,
        seat_histogram: histogram.sort.to_h.transform_keys(&:to_s)
      )
    end
end
