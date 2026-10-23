require "test_helper"

class Forecast::PollsterExclusionTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 8, 1)

  setup do
    @pollster = pollsters(:beacon_polling)
    @race = races(:senate_maine)
    @pollster.update!(excluded: true, exclusion_reason: "Fabricated polls")
  end

  test "arrays cannot bypass the exclusion in either averaging variant or the scatter chart" do
    poll = polls(:maine_poll_one)
    %i[exclude adjusted].each do |variant|
      average = Forecast::Averager.new(as_of: AS_OF, internals: variant, internals_shift: 3).for_race(@race, polls: [ poll ])
      assert_equal 0, average.poll_count
      assert_equal 0, average.weight
      assert_nil average.mean_margin
    end
    assert_nil Forecast::Averager.new(as_of: AS_OF).measurement(poll)
    assert_nil Site::Charts::PollsScatter.build(race: @race, polls: [ poll ], as_of: AS_OF)
  end

  test "exclusion is numerically equivalent to removing the pollster from every model input" do
    # Enough peers to form house-effect comparisons, plus partisan polls to
    # exercise both sides of the internal-poll adjustment estimate.
    5.times do |i|
      peer = create_pollster("Peer #{i}")
      [ nil, @race ].each do |race|
        create_poll(pollster: peer, race: race, field_end: AS_OF, sample_size: 600, results: { dem: 47 + i, rep: 45 })
      end
      create_poll(pollster: peer, field_end: AS_OF - 1, partisan: :dem, results: { dem: 55, rep: 40 })
    end
    [ nil, @race ].each do |race|
      create_poll(pollster: @pollster, race: race, field_end: AS_OF, sample_size: 2000, results: { dem: 70, rep: 20 })
      create_poll(pollster: @pollster, race: race, field_end: AS_OF - 1, partisan: :rep, results: { dem: 20, rep: 70 })
    end

    excluded = run_model
    assert_predicate excluded, :succeeded?
    assert_not_empty excluded.house_effects
    assert_operator excluded.params_snapshot.dig("internals_estimate", "pair_count"), :>, 0
    assert_equal [ @pollster.id ], excluded.excluded_pollster_ids
    assert_equal "Fabricated polls", excluded.params_snapshot.fetch("excluded_pollsters").sole.fetch("reason")
    assert_not excluded.house_effects.exists?(pollster_id: @pollster.id)

    @pollster.polls.destroy_all
    removed = run_model
    assert_same_numbers excluded, removed
  end

  test "a state change during a run cannot mix exclusion policies across its estimates" do
    expected = run_model
    original = Forecast::HouseEffects.method(:call)
    pollster = @pollster
    implementation = lambda do |**options|
      pollster.update!(excluded: false)
      original.call(**options)
    end
    actual = replacing(Forecast::HouseEffects, :call, implementation) { run_model }

    assert_equal [ @pollster.id ], actual.excluded_pollster_ids
    assert_not actual.pollster_exclusions_current?
    assert_same_numbers expected, actual
    assert_includes Poll.model_corpus, polls(:maine_poll_one)
  end

  private
    def run_model
      Forecast::Runner.call(trigger: :pollster_change, as_of: AS_OF, seed: 1234, n_sims: 200)
    end

    def assert_same_numbers(first, second)
      assert_equal first.forecasts.order(:variant, :race_id).pluck(:mean_margin, :p_dem_win, :effective_poll_weight),
                   second.forecasts.order(:variant, :race_id).pluck(:mean_margin, :p_dem_win, :effective_poll_weight)
      assert_equal first.chamber_forecasts.order(:variant, :chamber).pluck(:p_dem_control, :mean_dem_seats),
                   second.chamber_forecasts.order(:variant, :chamber).pluck(:p_dem_control, :mean_dem_seats)
      assert_equal first.house_effects.order(:pollster_id).pluck(:pollster_id, :effect_raw, :effect_shrunk),
                   second.house_effects.order(:pollster_id).pluck(:pollster_id, :effect_raw, :effect_shrunk)
      assert_equal first.params_snapshot.fetch("internals_estimate"), second.params_snapshot.fetch("internals_estimate")
    end
end
