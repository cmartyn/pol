require "test_helper"

# Expected numbers are hand-derived from the published shape:
#
#   shift = prior + (empirical_mean − prior) × n / (n + shrinkage_k)
#
# with prior 3.0 and shrinkage_k 10.0 from config/model_params.yml, and each
# pair's gap read dem−rep and signed toward the sponsor.
class Forecast::InternalsTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 8, 1)
  MATCHUP = "dem:ellis|rep:rivers".freeze

  setup do
    @beacon = pollsters(:beacon_polling)
    @cardinal = pollsters(:cardinal_research)
    @delta = pollsters(:delta_metrics)
    # The fixture race polls are part of the corpus; point them away from the
    # matchup under test so every race-level pair below is one this file
    # built. The generic-ballot fixture poll keeps its nil matchup — it IS
    # the field for the generic pairing test.
    Poll.where.not(race_id: nil).update_all(matchup_key: "dem:someone|rep:else")
  end

  def flagged(partisan:, results:, field_end: AS_OF, pollster: @beacon)
    create_poll(pollster: pollster, field_end: field_end, sample_size: 600,
                race: races(:senate_maine), matchup_key: MATCHUP,
                results: results, partisan: partisan, entry_mode: :nyt)
  end

  def peer(results:, field_end: AS_OF, pollster: @cardinal)
    create_poll(pollster: pollster, field_end: field_end, sample_size: 600,
                race: races(:senate_maine), matchup_key: MATCHUP,
                results: results, entry_mode: :nyt)
  end

  test "with no flagged polls the shift is the prior, from zero pairs" do
    estimate = Forecast::Internals.estimate(as_of: AS_OF)

    assert_equal 3.0, estimate.shift
    assert_equal 0, estimate.pair_count
    assert_nil estimate.empirical_mean
  end

  test "a flagged poll with no contemporaries contributes no pair" do
    flagged(partisan: :dem, results: { dem: 52.0, rep: 43.0 })

    estimate = Forecast::Internals.estimate(as_of: AS_OF)

    assert_equal 0, estimate.pair_count
    assert_equal 3.0, estimate.shift
  end

  test "one pair pulls the shift off the prior by 1/(1+k) of its excess" do
    # Flagged margin +9 against a same-day unflagged +3: gap 6 toward the
    # sponsor. shift = 3 + (6 − 3) × 1/11 = 3.2727…
    flagged(partisan: :dem, results: { dem: 52.0, rep: 43.0 })
    peer(results: { dem: 48.0, rep: 45.0 })

    estimate = Forecast::Internals.estimate(as_of: AS_OF)

    assert_equal 1, estimate.pair_count
    assert_in_delta 6.0, estimate.empirical_mean, 1e-9
    assert_in_delta 3.0 + (3.0 / 11.0), estimate.shift, 1e-9
  end

  test "a republican sponsor's gap is signed toward the republican side" do
    # Flagged margin −9 against unflagged +3: raw gap −12, sponsor-ward +12.
    flagged(partisan: :rep, results: { dem: 43.0, rep: 52.0 })
    peer(results: { dem: 48.0, rep: 45.0 })

    estimate = Forecast::Internals.estimate(as_of: AS_OF)

    assert_in_delta 12.0, estimate.empirical_mean, 1e-9
  end

  test "peers must share the race and matchup" do
    flagged(partisan: :dem, results: { dem: 52.0, rep: 43.0 })
    create_poll(pollster: @cardinal, field_end: AS_OF, sample_size: 600,
                race: races(:senate_maine), matchup_key: "dem:other|rep:rivers",
                results: { dem: 48.0, rep: 45.0 }, entry_mode: :nyt)

    assert_equal 0, Forecast::Internals.estimate(as_of: AS_OF).pair_count
  end

  test "peers outside the pair window do not count" do
    window = Pol::Params.fetch!(:internals, :pair_window_days)
    flagged(partisan: :dem, results: { dem: 52.0, rep: 43.0 })
    peer(results: { dem: 48.0, rep: 45.0 }, field_end: AS_OF - window - 1)

    assert_equal 0, Forecast::Internals.estimate(as_of: AS_OF).pair_count
  end

  test "flagged polls do not serve as each other's field" do
    flagged(partisan: :dem, results: { dem: 52.0, rep: 43.0 })
    flagged(partisan: :dem, results: { dem: 51.0, rep: 44.0 }, pollster: @delta)

    assert_equal 0, Forecast::Internals.estimate(as_of: AS_OF).pair_count
  end

  test "an ind-flagged poll neither informs the estimate nor blocks it" do
    flagged(partisan: :ind, results: { dem: 52.0, rep: 43.0 })
    peer(results: { dem: 48.0, rep: 45.0 })

    assert_equal 0, Forecast::Internals.estimate(as_of: AS_OF).pair_count
  end

  test "generic-ballot internals pair against generic-ballot peers" do
    create_poll(pollster: @beacon, field_end: AS_OF, sample_size: 600,
                results: { dem: 52.0, rep: 43.0 }, partisan: :dem, entry_mode: :nyt)
    # The fixture generic poll (46.5 − 44.5, four days older) is the field.
    estimate = Forecast::Internals.estimate(as_of: AS_OF)

    assert_equal 1, estimate.pair_count
    # Gap = 9 − 2 = 7 toward the sponsor.
    assert_in_delta 7.0, estimate.empirical_mean, 1e-9
  end
end
