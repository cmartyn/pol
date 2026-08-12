require "test_helper"

class Forecast::SimulatorTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 8, 11)   # 84 days out: t = 1 + 84/180 = 1.4666...

  # The default state for a test entry, by race id: one state from each census
  # division in turn, so consecutive ids land in different states AND different
  # divisions. Most tests here want two races sharing nothing but the national
  # error and could not have that if the default put neighbours together; the
  # ones that DO want a shared state or division say so explicitly. DC is
  # dropped because it has no race to give an id to.
  STATE_ROTATION = Pol::CensusDivisions::STATES_BY_DIVISION.values.then { |divisions|
    (0...divisions.map(&:size).max).flat_map { |index| divisions.filter_map { |states| states[index] } }
  }.excluding("DC").freeze

  # The three rungs of the correlation ladder, named so the assertions read.
  SAME_STATE = %w[GA GA].freeze                 # South Atlantic, one state
  SAME_DIVISION = %w[GA FL].freeze              # South Atlantic, two states
  DIFFERENT_DIVISIONS = %w[GA OR].freeze        # South Atlantic and Pacific

  # --- The fixed-seed golden ---------------------------------------------
  # Two Senate races, 100 simulations, seed 20260811. Race 1 is in New Jersey
  # (Middle Atlantic) and race 2 in Illinois (East North Central), so they
  # share the national error and nothing else. Every number below is what this
  # engine produces and must keep producing; the two tests after it are the
  # independent check that they are the right numbers — one rebuilding these
  # exact draws by hand from the design, one confirming the distribution they
  # come from is the normal it claims to be. Re-pinned in Phase 10, when the
  # single correlated term became four components.

  test "a fixed seed produces exactly these numbers" do
    result = simulate([ entry(1, mu: 0.0), entry(2, mu: 5.0) ], seed: 20260811, n_sims: 100)
    tossup, leaner = result.races

    assert_in_delta 1.4666667, result.time_multiplier, 1e-7
    assert_equal %w[NJ IL], [ tossup, leaner ].map { |race| state_for(race.race_id) }

    assert_equal 0.53, tossup.p_dem_win
    assert_equal 0.47, tossup.p_rep_win
    assert_equal 0.0, tossup.p_other_win
    assert_in_delta 0.713609, tossup.mean_margin, 1e-6
    assert_equal %w[5 25 50 75 95], tossup.percentiles.keys
    assert_in_delta(-14.873815, tossup.percentiles["5"], 1e-6)
    assert_in_delta(-6.549280, tossup.percentiles["25"], 1e-6)
    assert_in_delta 0.239188, tossup.percentiles["50"], 1e-6
    assert_in_delta 7.270631, tossup.percentiles["75"], 1e-6
    assert_in_delta 15.522623, tossup.percentiles["95"], 1e-6

    assert_equal 0.78, leaner.p_dem_win
    assert_in_delta 5.781288, leaner.mean_margin, 1e-6

    senate = chamber(result, :senate)
    assert_equal({ "34" => 13, "35" => 43, "36" => 44 }, senate.seat_histogram)
    assert_in_delta 35.31, senate.mean_dem_seats, 1e-9
    # Two seats up cannot get anyone to a majority: 34 holdovers plus at most
    # two is 36, and 31 plus nothing is 31.
    assert_equal 0.0, senate.p_dem_control
    assert_equal 0.0, senate.p_rep_control
  end

  # The golden's paired check, and the reason it is a golden rather than a
  # record of a bug: the same two races rebuilt draw for draw from the design
  # — one national series, then one per census division in Census order, then
  # one per state alphabetically, then each race's own noise in entry order —
  # and composed by hand. Written from the specification rather than from the
  # implementation, so a change to the composition rule fails here saying what
  # broke, instead of leaving five moved numbers above to be re-pinned on
  # faith.
  test "the golden is exactly the four-component sum of its own draws" do
    entries = [ entry(1, mu: 0.0), entry(2, mu: 5.0) ]
    result = simulate(entries, seed: 20260811, n_sims: 100)
    multiplier = result.time_multiplier
    gaussian = Forecast::Gaussian.new(Random.new(20260811))
    draws = ->(sigma) { Array.new(100) { gaussian.next * sigma * multiplier } }

    national = draws.call(Pol::Params.fetch!(:error_model, :sigma_national))
    # Race 1 is in Middle Atlantic and race 2 in East North Central, which is
    # the order the Census lists them; the states sort the other way round.
    divisions = [ "Middle Atlantic", "East North Central" ].index_with { draws.call(2.0) }
    states = entries.map(&:state).sort.index_with { draws.call(2.0) }

    entries.zip(result.races).each do |entry, outcome|
      own = draws.call(entry.sigma)
      margins = 100.times.map do |index|
        entry.mu + national[index] + divisions.fetch(Pol::CensusDivisions.for(entry.state))[index] +
          states.fetch(entry.state)[index] + own[index]
      end

      assert_in_delta margins.sum / 100, outcome.mean_margin, 1e-12
      assert_in_delta margins.count(&:positive?) / 100.0, outcome.p_dem_win, 1e-12
      assert_in_delta margins.sort[4], outcome.percentiles["5"], 1e-12
      assert_in_delta margins.sort[49], outcome.percentiles["50"], 1e-12
      assert_in_delta margins.sort[94], outcome.percentiles["95"], 1e-12
    end
  end

  # And the same scenario at 200,000 draws against the closed form. A race at
  # mu = +5 with an idiosyncratic sigma of 4, on top of the three correlated
  # terms and inflated by t, is Normal(5, sqrt(3² + 2² + 2² + 4²) × t).
  test "the simulated distribution is the normal it claims to be" do
    result = simulate([ entry(1, mu: 5.0) ], seed: 5, n_sims: 200_000)
    race = result.races.first
    correlated = %i[sigma_national sigma_regional sigma_state].sum { |key| Pol::Params.fetch!(:error_model, key)**2 }
    sigma = Math.sqrt(correlated + (4.0**2)) * result.time_multiplier
    analytic = 0.5 * (1 + Math.erf((5.0 / sigma) / Math.sqrt(2)))

    assert_in_delta Math.sqrt(33), Math.sqrt(correlated + (4.0**2)), 1e-9
    assert_in_delta analytic, race.p_dem_win, 0.005
    assert_in_delta 5.0, race.mean_margin, 0.05
    assert_in_delta 5.0, race.percentiles["50"], 0.1
    assert_in_delta 5.0 - (1.6448536 * sigma), race.percentiles["5"], 0.15
    assert_in_delta 5.0 + (1.6448536 * sigma), race.percentiles["95"], 0.15
  end

  test "the same seed twice is the same run twice" do
    entries = [ entry(1, mu: 0.0), entry(2, mu: -3.0), entry(3, chamber: :house, mu: 1.0, sigma: 6.0) ]

    first = simulate(entries, seed: 4242, n_sims: 500)
    second = simulate(entries, seed: 4242, n_sims: 500)

    assert_equal first.races.map(&:to_h), second.races.map(&:to_h)
    assert_equal first.chambers.map(&:to_h), second.chambers.map(&:to_h)
  end

  test "a different seed is a different run" do
    entries = [ entry(1, mu: 0.0) ]

    refute_equal simulate(entries, seed: 1, n_sims: 500).races.first.mean_margin,
                 simulate(entries, seed: 2, n_sims: 500).races.first.mean_margin
  end

  test "the order of the entries is part of what the seed determines" do
    forwards = simulate([ entry(1, mu: 0.0), entry(2, mu: 0.0) ], seed: 9, n_sims: 200)
    backwards = simulate([ entry(2, mu: 0.0), entry(1, mu: 0.0) ], seed: 9, n_sims: 200)

    # Same seed, same draws, handed out in the other order — so race 1's
    # numbers move. The runner therefore always orders races by id.
    refute_equal forwards.races.first.mean_margin, backwards.races.last.mean_margin
  end

  # --- The shared errors ---------------------------------------------------
  #
  # Every test in this section measures the same thing: how often two races at
  # mu = 0 split, one going each way. For two mean-zero jointly-normal margins
  # with correlation rho that share is 1/2 − arcsin(rho)/pi (Sheppard's theorem
  # on median dichotomy), and with two Senate entries the seat histogram counts
  # it directly — bucket "35" is the worlds where exactly one side A won. So
  # each rung of the correlation ladder has a closed form to hit, not just an
  # inequality, and the ladder is checked against the arithmetic rather than
  # against itself.

  test "the national error is shared, so races move together" do
    # Almost no independent error is left, so what moves either race is the
    # correlated structure; two races in different divisions share only the
    # national term, and rho is its share of the correlated variance.
    rate = splits_between(*DIFFERENT_DIVISIONS)

    assert_in_delta split_share(9.0 / 17.0), rate, 0.02
    assert_in_delta 0.3224, rate, 0.02
    # Independent races would split half the time. These do it a third of the
    # time, which is the whole reason a chamber forecast is not 435 coin flips.
    assert_operator rate, :<, 0.40
  end

  # F2: a refactor that drew the shared series once per chamber loop, instead
  # of once for the whole call, would leave every test above green while
  # quietly severing the House-Senate correlation. With the regional and state
  # terms switched off, the national series is the only thing either race has
  # apart from its own ~0 noise — so if it crosses the chamber boundary the two
  # win the identical set of simulated worlds, and their win counts match
  # exactly rather than approximately. Two different states in two different
  # divisions, so nothing but the nation could be doing the work.
  # (Verified against a hand-rolled per-chamber-loop mutation: every seed tried
  # decorrelates this pair's counts by several out of 2000.)
  test "the national error is shared across chambers too, not just within one" do
    with_params(error_model: { sigma_regional: 0.0, sigma_state: 0.0 }) do
      entries = [
        entry(1, chamber: :senate, state: DIFFERENT_DIVISIONS.first, mu: 0.0, sigma: 0.001),
        entry(2, chamber: :house, state: DIFFERENT_DIVISIONS.last, mu: 0.0, sigma: 0.001)
      ]
      senate_race, house_race = simulate(entries, seed: 11, n_sims: 2000).races

      assert_equal senate_race.p_dem_win, house_race.p_dem_win
    end
  end

  # The state term is the structural gain of Phase 10, and this is it: a
  # state's Senate race and its districts read the SAME state draw, so they
  # move together beyond anything the national term explains. With the
  # idiosyncratic term at ~0 the two share their entire error and win the
  # identical set of simulated worlds — exactly, not approximately.
  test "a state's senate race and its districts share that state's error" do
    entries = [
      entry(1, chamber: :senate, state: "GA", mu: 0.0, sigma: 0.001),
      entry(2, chamber: :house, state: "GA", mu: 0.0, sigma: 0.001),
      entry(3, chamber: :house, state: "GA", mu: 0.0, sigma: 0.001)
    ]
    result = simulate(entries, seed: 11, n_sims: 2000)
    senate_race, first_district, second_district = result.races

    assert_equal senate_race.p_dem_win, first_district.p_dem_win
    assert_equal senate_race.p_dem_win, second_district.p_dem_win
    # Per world, not just in aggregate: Georgia's two districts are never split
    # between the parties, because there is nothing left to split them.
    assert_equal [ "0", "2" ], chamber(result, :house).seat_histogram.keys
  end

  # The ladder. Same state co-moves most (N + D + S), same division next
  # (N + D), different divisions least (N alone) — each against its own closed
  # form, so the ordering is a consequence of the arithmetic rather than the
  # claim being tested.
  test "co-movement falls off with distance: same state, then same division, then neither" do
    one_state = splits_between(*SAME_STATE)
    one_division = splits_between(*SAME_DIVISION)
    apart = splits_between(*DIFFERENT_DIVISIONS)

    # Shared variance over total: 17/17 in one state, (9 + 4)/17 in one
    # division, 9/17 with only the nation in common.
    assert_in_delta split_share(1.0), one_state, 0.02
    assert_in_delta split_share(13.0 / 17.0), one_division, 0.02
    assert_in_delta split_share(9.0 / 17.0), apart, 0.02

    assert_operator one_state, :<, one_division
    assert_operator one_division, :<, apart
  end

  # The claim the whole design rests on: one race's margin distribution keeps
  # the width Phase 3 calibrated, while the seat distribution built out of 35
  # of them widens materially. Both halves are measured against the same board
  # run under the pre-Phase-10 configuration — one correlated term of 2.5 and
  # an idiosyncratic 4.0, which is the identical per-race total of 4.7170 —
  # so the only thing that differs between the two runs is where the variance
  # sits, not how much of it there is.
  BEFORE_PHASE_10 = {
    error_model: { sigma_national: 2.5, sigma_regional: 0.0, sigma_state: 0.0, sigma_senate_polled: 4.0 }
  }.freeze

  test "the four components reallocate variance rather than inflating it" do
    sigma = Pol::Params.fetch!(:error_model, :sigma_senate_polled)
    states = 35.times.map { |index| state_for(index) }
    after = simulate(35.times.map { |index| entry(index, mu: 0.0, sigma: sigma) }, seed: 505, n_sims: 20_000)
    before = with_params(BEFORE_PHASE_10) do
      simulate(35.times.map { |index| entry(index, mu: 0.0, sigma: 4.0) }, seed: 505, n_sims: 20_000)
    end

    # Not inflation: one race's margin distribution is exactly as wide as it
    # was, at Phase 3's AAPOR-calibrated total for a polled Senate race.
    expected = Math.sqrt((2.5**2) + (4.0**2)) * after.time_multiplier
    assert_in_delta 4.7170 * after.time_multiplier, expected, 1e-4
    assert_in_delta expected, spread(after.races.first), 0.1
    assert_in_delta spread(before.races.first), spread(after.races.first), 0.15

    # Reallocation: the same variance, arriving through channels that do not
    # average away, makes the chamber distribution a fifth wider. Both numbers
    # are checked against the closed form rather than merely recorded — for
    # mean-zero races the seat variance is n/4 plus every pair's covariance,
    # and the covariance of a pair with correlation rho is arcsin(rho)/(2π).
    assert_in_delta analytic_seat_sd(states, own: 4.0, national: 2.5, regional: 0.0, state: 0.0),
                    seat_sd(chamber(before, :senate)), 0.3
    assert_in_delta analytic_seat_sd(states, own: sigma, national: 3.0, regional: 2.0, state: 2.0),
                    seat_sd(chamber(after, :senate)), 0.3

    widened = seat_sd(chamber(after, :senate)) / seat_sd(chamber(before, :senate))
    assert_operator widened, :>, 1.15, "seat SD #{seat_sd(chamber(after, :senate)).round(2)} " \
                                       "against #{seat_sd(chamber(before, :senate)).round(2)}"
  end

  test "independent error alone would give the middle outcome most of the time" do
    entries = [ entry(1, sigma: 50.0), entry(2, sigma: 50.0) ]
    senate = chamber(simulate(entries, seed: 11, n_sims: 2000), :senate)

    assert_in_delta 0.5, split_rate(senate, 2000), 0.05
  end

  # --- Where the shared draws come from ------------------------------------

  test "a race with no state cannot be simulated" do
    stateless = entry(2)
    stateless.state = nil

    error = assert_raises(ArgumentError) { simulate([ entry(1), stateless ], seed: 1, n_sims: 10) }
    assert_match(/entry 2 has no state/, error.message)
  end

  test "a state outside the census table cannot be simulated" do
    assert_raises(KeyError) { simulate([ entry(1, state: "PR") ], seed: 1, n_sims: 10) }
  end

  # The hot loop's budget, pinned as arithmetic rather than as a stopwatch.
  # Four components could cost four draws per race per world; they cost one,
  # because the three shared series are drawn once and read by everyone who
  # belongs to them. On the live board that is the difference between 4.7
  # million draws and 18.8 million, and it is why a full 470-race run still
  # measures around two seconds against a sixty-second budget.
  test "the shared draws are taken once per simulated world, not once per race" do
    counter = CountingGaussian.new(Random.new(4))
    entries = [ entry(1, state: "GA"), entry(2, state: "FL"), entry(3, state: "GA"),
                entry(4, state: "OR"), entry(5, state: "OR", certain: side(:dem)) ]

    stubbing(Forecast::Gaussian, :new, counter) { simulate(entries, seed: 4, n_sims: 100) }

    # 1 national + 2 divisions (South Atlantic, Pacific) + 3 states + 4
    # contested races = 10 series of 100. The certain race takes nothing.
    assert_equal 1000, counter.count
  end

  class CountingGaussian
    attr_reader :count

    def initialize(random)
      @gaussian = Forecast::Gaussian.new(random)
      @count = 0
    end

    def next
      @count += 1
      @gaussian.next
    end
  end

  # The shared series are drawn in a canonical order — Census order for
  # divisions, alphabetical for states — rather than in the order the entries
  # arrive, so a race added in a state already on the board leaves every other
  # race's shared error untouched. Without that, seeding a new district in
  # Georgia would silently move Oregon. Idiosyncratic sigma is zero here so
  # that what is left in the margin is exactly the shared part; the own draws
  # are still taken, they just contribute nothing.
  test "the shared draws do not depend on the order the states arrive in" do
    forwards = simulate([ entry(1, state: "OR", sigma: 0.0), entry(2, state: "GA", sigma: 0.0) ],
                        seed: 71, n_sims: 500)
    backwards = simulate([ entry(2, state: "GA", sigma: 0.0), entry(1, state: "OR", sigma: 0.0) ],
                         seed: 71, n_sims: 500)

    assert_equal forwards.races.find { |race| race.race_id == 1 }.percentiles,
                 backwards.races.find { |race| race.race_id == 1 }.percentiles
    assert_equal forwards.races.find { |race| race.race_id == 2 }.percentiles,
                 backwards.races.find { |race| race.race_id == 2 }.percentiles
  end

  # --- Chamber control ----------------------------------------------------

  test "the senate is counted from the holdovers up" do
    result = simulate(35.times.map { |index| entry(index, mu: 0.0) }, seed: 99, n_sims: 2000)
    senate = chamber(result, :senate)

    # 34 Democratic-caucus holdovers plus about half of 35 seats.
    assert_in_delta 51.5, senate.mean_dem_seats, 0.5
    assert_equal 2000, senate.seat_histogram.values.sum
    assert_operator senate.seat_histogram.keys.map(&:to_i).min, :>=, 34
    assert_operator senate.seat_histogram.keys.map(&:to_i).max, :<=, 69
    assert_in_delta 1.0, senate.p_dem_control + senate.p_rep_control, 1e-9
    assert_in_delta 0.5, senate.p_dem_control, 0.1
  end

  # 34 + 16 = 50 Democratic-caucus seats and 31 + 18 = 49 Republican, with one
  # tossup left. A Republican vice president means Republicans control at 50
  # and Democrats need 51 — so if the uncommitted independent wins that seat,
  # nobody controls the Senate. The two probabilities are meant to sum to less
  # than one here; the missing 0.491 is the forecast.
  test "an uncommitted independent can leave the senate under nobody's control" do
    result = simulate(balance_of_power_entries(caucus: :uncommitted), seed: 7, n_sims: 1000)
    senate = chamber(result, :senate)

    assert_equal 0.491, result.races.last.p_other_win
    assert_equal 0.0, senate.p_dem_control
    assert_equal 0.509, senate.p_rep_control
    assert_in_delta 0.509, senate.p_dem_control + senate.p_rep_control, 1e-9
    # The Democratic caucus never gets past 50 whoever wins.
    assert_equal({ "50" => 1000 }, senate.seat_histogram)
  end

  test "the same independent with a declared caucus decides the chamber" do
    result = simulate(balance_of_power_entries(caucus: :dem), seed: 7, n_sims: 1000)
    senate = chamber(result, :senate)

    # Identical race, identical draws — only the caucus flag differs.
    assert_equal 0.491, result.races.last.p_other_win
    assert_equal 0.491, senate.p_dem_control
    assert_equal 0.509, senate.p_rep_control
    assert_in_delta 1.0, senate.p_dem_control + senate.p_rep_control, 1e-9
    assert_equal({ "50" => 509, "51" => 491 }, senate.seat_histogram)
  end

  # The two Senate thresholds are derived, not written down: a tie is half of
  # chambers.senate_total_seats and a majority is one more, and the vice
  # president's party is the one that controls at a tie. Flipping vp_party is
  # the proof that both numbers come from the file — the same 50 Democratic
  # seats that control nothing under a Republican VP control outright under a
  # Democratic one.
  test "the senate thresholds come from senate_total_seats and vp_party" do
    assert_equal 100, Pol::Params.fetch!(:chambers, :senate_total_seats)

    entries = balance_of_power_entries(caucus: :uncommitted)
    republican_vp = chamber(simulate(entries, seed: 7, n_sims: 1000), :senate)

    assert_equal 0.0, republican_vp.p_dem_control
    assert_equal 0.509, republican_vp.p_rep_control

    with_params(chambers: { vp_party: "dem" }) do
      democratic_vp = chamber(simulate(entries, seed: 7, n_sims: 1000), :senate)

      # 50 Democratic-caucus seats is now control, and 50 Republican is not.
      assert_equal 1.0, democratic_vp.p_dem_control
      assert_equal 0.0, democratic_vp.p_rep_control
    end
  end

  test "a bigger senate would need a bigger majority" do
    entries = Array.new(17) { |index| entry(index, certain: side(:dem)) }

    # 34 holdovers + 17 = 51, a majority of 100.
    assert_equal 1.0, chamber(simulate(entries, seed: 1, n_sims: 10), :senate).p_dem_control

    with_params(chambers: { senate_total_seats: 120 }) do
      # The same 51 seats is nowhere near a majority of 120.
      assert_equal 0.0, chamber(simulate(entries, seed: 1, n_sims: 10), :senate).p_dem_control
    end
  end

  test "the house needs 218 seats" do
    majority = Pol::Params.fetch!(:chambers, :house_majority_seats)
    entries = Array.new(220) { |index| entry(index, chamber: :house, certain: side(:dem)) }
    entries += Array.new(215) { |index| entry(1000 + index, chamber: :house, certain: side(:rep)) }

    house = chamber(simulate(entries, seed: 3, n_sims: 50), :house)

    assert_equal 218, majority
    assert_equal 1.0, house.p_dem_control
    assert_equal 0.0, house.p_rep_control
    assert_in_delta 220.0, house.mean_dem_seats, 1e-9
    assert_equal({ "220" => 50 }, house.seat_histogram)
  end

  test "one seat short of a majority is not a majority" do
    entries = Array.new(217) { |index| entry(index, chamber: :house, certain: side(:dem)) }
    entries += Array.new(218) { |index| entry(1000 + index, chamber: :house, certain: side(:rep)) }

    house = chamber(simulate(entries, seed: 3, n_sims: 50), :house)

    assert_equal 0.0, house.p_dem_control
    assert_equal 1.0, house.p_rep_control
  end

  test "both chambers are always reported, even with nothing to report" do
    result = simulate([], seed: 1, n_sims: 10)

    assert_equal %i[senate house], result.chambers.map(&:chamber)
    assert_equal 34.0, chamber(result, :senate).mean_dem_seats
    assert_equal 0.0, chamber(result, :house).mean_dem_seats
  end

  # --- Win probabilities --------------------------------------------------

  test "an independent's chances land in p_other_win however they caucus" do
    entries = [ entry(1, mu: 20.0, side_a: side(:ind, :dem, "Ida Nunn")) ]
    race = simulate(entries, seed: 2, n_sims: 500).races.first

    assert_equal 0.0, race.p_dem_win
    assert_operator race.p_other_win, :>, 0.9
    assert_in_delta 1.0, race.p_dem_win + race.p_rep_win + race.p_other_win, 1e-9
  end

  test "the three probabilities always sum to one" do
    entries = [ entry(1, mu: 0.0), entry(2, mu: -30.0), entry(3, mu: 12.0, side_a: side(:ind, :uncommitted)) ]

    simulate(entries, seed: 8, n_sims: 500).races.each do |race|
      assert_in_delta 1.0, race.p_dem_win + race.p_rep_win + race.p_other_win, 1e-9
    end
  end

  test "a certain race is certain, contributes a seat and takes no noise" do
    entries = [ entry(1, mu: 7.5, certain: side(:dem, :dem, "Ada Dean")) ]
    result = simulate(entries, seed: 6, n_sims: 100)
    race = result.races.first

    assert_equal 1.0, race.p_dem_win
    assert_equal 0.0, race.p_rep_win
    assert_equal 7.5, race.mean_margin
    assert_equal({ "5" => 7.5, "25" => 7.5, "50" => 7.5, "75" => 7.5, "95" => 7.5 }, race.percentiles)
    assert_equal 35.0, chamber(result, :senate).mean_dem_seats
  end

  test "certain races do not consume draws, so the rest of the run is unchanged" do
    contested = [ entry(1, mu: 0.0), entry(2, mu: 0.0) ]
    with_certain = [ entry(3, mu: 9.0, certain: side(:rep)) ] + contested

    assert_equal simulate(contested, seed: 77, n_sims: 300).races.map(&:mean_margin),
                 simulate(with_certain, seed: 77, n_sims: 300).races.drop(1).map(&:mean_margin)
  end

  # --- The time multiplier ------------------------------------------------

  test "the time multiplier widens every sigma and is capped" do
    assert_in_delta 1.0, multiplier_on(Date.new(2026, 11, 3)), 1e-12
    assert_in_delta 1.5, multiplier_on(Date.new(2026, 8, 5)), 1e-12
    assert_in_delta 1.75, multiplier_on(Date.new(2026, 6, 1)), 1e-12
    assert_in_delta 1.75, multiplier_on(Date.new(2025, 1, 1)), 1e-12
    # Past the election it floors at 1 rather than shrinking or inverting.
    assert_in_delta 1.0, multiplier_on(Date.new(2026, 12, 1)), 1e-12
  end

  # With mu = 0 the margin is (national + own error) × t, so the same seed at
  # two dates gives margins in exactly the ratio of the two multipliers.
  test "sigmas scale exactly with the time multiplier" do
    entries = [ entry(1, mu: 0.0) ]
    early = Forecast::Simulator.new(entries: entries, seed: 31, as_of: Date.new(2026, 6, 1), n_sims: 400).call
    late = Forecast::Simulator.new(entries: entries, seed: 31, as_of: Date.new(2026, 11, 3), n_sims: 400).call

    assert_in_delta 1.75, early.races.first.percentiles["95"] / late.races.first.percentiles["95"], 1e-9
    assert_in_delta 1.75, early.races.first.percentiles["5"] / late.races.first.percentiles["5"], 1e-9
    assert_operator early.races.first.percentiles["95"], :>, late.races.first.percentiles["95"]
  end

  # --- Percentiles --------------------------------------------------------

  test "the percentiles are in order and bracket the mean" do
    race = simulate([ entry(1, mu: 3.0) ], seed: 12, n_sims: 2000).races.first
    values = race.percentiles.values

    assert_equal values.sort, values
    assert_operator values.first, :<, race.mean_margin
    assert_operator values.last, :>, race.mean_margin
  end

  test "the median splits the simulations in half" do
    result = simulate([ entry(1, mu: 3.0) ], seed: 13, n_sims: 1000)
    race = result.races.first

    # p50 is the 500th smallest of 1,000 draws, and p_dem_win is the share
    # above zero, so a positive median means the race is a favourite.
    assert_operator race.percentiles["50"], :>, 0
    assert_operator race.p_dem_win, :>, 0.5
  end

  private
    def simulate(entries, seed:, n_sims:)
      Forecast::Simulator.new(entries: entries, seed: seed, as_of: AS_OF, n_sims: n_sims).call
    end

    def multiplier_on(as_of)
      Forecast::Simulator.new(entries: [], seed: 1, as_of: as_of, n_sims: 1).time_multiplier
    end

    def chamber(result, name)
      result.chambers.find { |outcome| outcome.chamber == name }
    end

    # Two Senate races at mu = 0 with next to no error of their own, one in
    # each of the given states: the standard instrument for measuring how much
    # of a pair's error is shared.
    def splits_between(state_a, state_b, n_sims: 20_000)
      entries = [ entry(1, state: state_a, mu: 0.0, sigma: 0.001),
                  entry(2, state: state_b, mu: 0.0, sigma: 0.001) ]

      split_rate(chamber(simulate(entries, seed: 11, n_sims: n_sims), :senate), n_sims)
    end

    # Of two Senate seats in doubt, the share of worlds where exactly one went
    # to side A. 34 holdovers + 1 is the middle bucket.
    def split_rate(senate, n_sims)
      senate.seat_histogram.fetch("35", 0).to_f / n_sims
    end

    # For two mean-zero jointly-normal margins with correlation rho, the share
    # of draws where exactly one is positive: 1/2 − arcsin(rho)/pi.
    def split_share(rho)
      0.5 - (Math.asin(rho) / Math::PI)
    end

    # A race's standard deviation, read off the 5th and 95th percentiles of the
    # margins the simulator actually produced (p95 − p5 = 2 × 1.6448536 sigma
    # for a normal). Nothing in the engine reports a standard deviation, and
    # inferring one from the output is the point — it is the width a reader of
    # the race page sees.
    def spread(race)
      (race.percentiles["95"] - race.percentiles["5"]) / (2 * 1.6448536)
    end

    # The seat-count standard deviation these states imply, from the
    # arithmetic rather than from a simulation: n mean-zero races each
    # contribute 1/4, and each pair contributes 2 × arcsin(rho)/(2π), where rho
    # is the share of the pair's variance that the two hold in common.
    def analytic_seat_sd(states, own:, national:, regional:, state:)
      total = (national**2) + (regional**2) + (state**2) + (own**2)
      variance = states.size * 0.25

      states.combination(2) do |first, second|
        shared = national**2
        shared += regional**2 if Pol::CensusDivisions.for(first) == Pol::CensusDivisions.for(second)
        shared += state**2 if first == second
        variance += Math.asin(shared / total) / Math::PI
      end

      Math.sqrt(variance)
    end

    def seat_sd(chamber_outcome)
      histogram = chamber_outcome.seat_histogram
      total = histogram.values.sum
      mean = histogram.sum { |seats, count| seats.to_i * count }.to_f / total

      Math.sqrt(histogram.sum { |seats, count| count * ((seats.to_i - mean)**2) }.to_f / total)
    end

    def side(party, caucus = party, name = nil)
      Forecast::RaceModel::Side.new(party: party, caucus: caucus, name: name)
    end

    def entry(race_id, chamber: :senate, state: nil, mu: 0.0, sigma: 4.0, side_a: nil, side_b: nil, certain: nil)
      Forecast::Simulator::Entry.new(
        race_id: race_id, chamber: chamber, state: state || state_for(race_id), mu: mu, sigma: sigma,
        weight: 0.0, side_a: side_a || side(:dem), side_b: side_b || side(:rep), certain: certain
      )
    end

    # The default state for a test entry, by race id. STATE_ROTATION walks the
    # nine census divisions round-robin, so consecutive ids land in different
    # states AND different divisions: most of the tests here want two races
    # sharing nothing but the national error, and could not have that if the
    # default put neighbours together. The tests that DO want a shared state or
    # division pass one explicitly.
    def state_for(race_id)
      STATE_ROTATION[race_id % STATE_ROTATION.size]
    end


    # 16 certain Democratic seats, 18 certain Republican, and one race between
    # an independent and a Republican that decides everything.
    def balance_of_power_entries(caucus:)
      entries = Array.new(16) { |index| entry(100 + index, certain: side(:dem)) }
      entries += Array.new(18) { |index| entry(200 + index, certain: side(:rep)) }
      entries << entry(300, mu: 0.0, side_a: side(:ind, caucus, "Dan Osborn"))
    end
end
