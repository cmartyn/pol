require "test_helper"

class Forecast::SimulatorTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 8, 11)   # 84 days out: t = 1 + 84/180 = 1.4666...

  # --- The fixed-seed golden ---------------------------------------------
  # Two Senate races, 100 simulations, seed 20260811. Every number below is
  # what this engine produced the first time it ran and must keep producing;
  # the assertions after it are the independent check that those numbers are
  # the right ones.

  test "a fixed seed produces exactly these numbers" do
    result = simulate([ entry(1, mu: 0.0), entry(2, mu: 5.0) ], seed: 20260811, n_sims: 100)
    tossup, leaner = result.races

    assert_in_delta 1.4666667, result.time_multiplier, 1e-7

    assert_equal 0.53, tossup.p_dem_win
    assert_equal 0.47, tossup.p_rep_win
    assert_equal 0.0, tossup.p_other_win
    assert_in_delta 0.003754, tossup.mean_margin, 1e-6
    assert_equal %w[5 25 50 75 95], tossup.percentiles.keys
    assert_in_delta(-13.665866, tossup.percentiles["5"], 1e-6)
    assert_in_delta(-5.494878, tossup.percentiles["25"], 1e-6)
    assert_in_delta 0.491860, tossup.percentiles["50"], 1e-6
    assert_in_delta 5.350244, tossup.percentiles["75"], 1e-6
    assert_in_delta 11.705250, tossup.percentiles["95"], 1e-6

    assert_equal 0.84, leaner.p_dem_win
    assert_in_delta 6.201546, leaner.mean_margin, 1e-6

    senate = chamber(result, :senate)
    assert_equal({ "34" => 8, "35" => 47, "36" => 45 }, senate.seat_histogram)
    assert_in_delta 35.37, senate.mean_dem_seats, 1e-9
    # Two seats up cannot get anyone to a majority: 34 holdovers plus at most
    # two is 36, and 31 plus nothing is 31.
    assert_equal 0.0, senate.p_dem_control
    assert_equal 0.0, senate.p_rep_control
  end

  # The same scenario at 200,000 draws, against the closed form. This is what
  # makes the golden above a golden rather than a record of a bug: a race at
  # mu = +5 with sigma 4 and a national sigma of 2.5, inflated by t, is
  # Normal(5, 6.918).
  test "the simulated distribution is the normal it claims to be" do
    result = simulate([ entry(1, mu: 5.0) ], seed: 5, n_sims: 200_000)
    race = result.races.first
    sigma = Math.sqrt((2.5**2) + (4.0**2)) * result.time_multiplier
    analytic = 0.5 * (1 + Math.erf((5.0 / sigma) / Math.sqrt(2)))

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

  # --- The shared national error -----------------------------------------

  test "the national error is shared, so races move together" do
    entries = [ entry(1, mu: 0.0, sigma: 0.001), entry(2, mu: 0.0, sigma: 0.001) ]
    result = simulate(entries, seed: 11, n_sims: 2000)

    # With almost no independent error left, the only thing moving either race
    # is the national environment, so they win and lose together.
    assert_in_delta result.races.first.p_dem_win, result.races.last.p_dem_win, 0.01

    senate = chamber(result, :senate)
    # ... and the seat histogram is bimodal: both seats or neither, never one.
    assert_equal [ "34", "36" ], senate.seat_histogram.keys
  end

  test "independent error alone would give the middle outcome most of the time" do
    entries = [ entry(1, mu: 0.0, sigma: 50.0), entry(2, mu: 0.0, sigma: 50.0) ]
    senate = chamber(simulate(entries, seed: 11, n_sims: 2000), :senate)

    assert_in_delta 0.5, senate.seat_histogram.fetch("35").to_f / 2000, 0.05
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
  # than one here; the missing 0.507 is the forecast.
  test "an uncommitted independent can leave the senate under nobody's control" do
    result = simulate(balance_of_power_entries(caucus: :uncommitted), seed: 7, n_sims: 1000)
    senate = chamber(result, :senate)

    assert_equal 0.507, result.races.last.p_other_win
    assert_equal 0.0, senate.p_dem_control
    assert_equal 0.493, senate.p_rep_control
    assert_in_delta 0.493, senate.p_dem_control + senate.p_rep_control, 1e-9
    # The Democratic caucus never gets past 50 whoever wins.
    assert_equal({ "50" => 1000 }, senate.seat_histogram)
  end

  test "the same independent with a declared caucus decides the chamber" do
    result = simulate(balance_of_power_entries(caucus: :dem), seed: 7, n_sims: 1000)
    senate = chamber(result, :senate)

    # Identical race, identical draws — only the caucus flag differs.
    assert_equal 0.507, result.races.last.p_other_win
    assert_equal 0.507, senate.p_dem_control
    assert_equal 0.493, senate.p_rep_control
    assert_in_delta 1.0, senate.p_dem_control + senate.p_rep_control, 1e-9
    assert_equal({ "50" => 493, "51" => 507 }, senate.seat_histogram)
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

    def side(party, caucus = party, name = nil)
      Forecast::RaceModel::Side.new(party: party, caucus: caucus, name: name)
    end

    def entry(race_id, chamber: :senate, mu: 0.0, sigma: 4.0, side_a: nil, side_b: nil, certain: nil)
      Forecast::Simulator::Entry.new(
        race_id: race_id, chamber: chamber, mu: mu, sigma: sigma, weight: 0.0,
        side_a: side_a || side(:dem), side_b: side_b || side(:rep), certain: certain
      )
    end

    # 16 certain Democratic seats, 18 certain Republican, and one race between
    # an independent and a Republican that decides everything.
    def balance_of_power_entries(caucus:)
      entries = Array.new(16) { |index| entry(100 + index, certain: side(:dem)) }
      entries += Array.new(18) { |index| entry(200 + index, certain: side(:rep)) }
      entries << entry(300, mu: 0.0, side_a: side(:ind, caucus, "Dan Osborn"))
    end
end
