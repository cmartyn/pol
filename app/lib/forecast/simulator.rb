# The Monte Carlo. Every simulated world gets one national error, drawn once
# and applied to every race in both chambers, plus an independent error per
# race. That shared term is the whole point: it is what makes a bad night for
# one party a bad night everywhere, and what keeps 435 near-certain districts
# from averaging into a chamber forecast of false precision.
#
# Margins are side A minus side B in percentage points. Given the same seed and
# the same entries in the same order, every number this produces is identical.
class Forecast::Simulator
  # What the simulator needs to know about a race; no ActiveRecord below this
  # line. `sigma` is the election-day-equivalent standard deviation — the time
  # multiplier is applied here, once, to every sigma including the national one.
  # `certain` is a Side when the race has only one possible winner.
  Entry = Struct.new(:race_id, :chamber, :mu, :sigma, :weight, :side_a, :side_b, :certain, keyword_init: true)

  RaceOutcome = Struct.new(
    :race_id, :p_dem_win, :p_rep_win, :p_other_win, :mean_margin, :percentiles, :weight,
    keyword_init: true
  )

  ChamberOutcome = Struct.new(
    :chamber, :p_dem_control, :p_rep_control, :mean_dem_seats, :seat_histogram,
    keyword_init: true
  )

  Result = Struct.new(:races, :chambers, :n_sims, :time_multiplier, :seed, keyword_init: true)

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

    # One national environment per simulated world, shared by every race.
    national_sigma = Pol::Params.fetch!(:error_model, :sigma_national) * multiplier
    national = Array.new(n_sims) { gaussian.next * national_sigma }

    races = entries.map do |entry|
      simulate(entry, national: national, gaussian: gaussian, multiplier: multiplier,
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
    def simulate(entry, national:, gaussian:, multiplier:, tally:)
      return certain_outcome(entry, tally) if entry.certain

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
        margin = mu + national[index] + (gaussian.next * sigma)
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
      dem_needs = vp_party == "dem" ? 50 : 51
      rep_needs = vp_party == "rep" ? 50 : 51

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
