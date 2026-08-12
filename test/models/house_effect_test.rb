require "test_helper"

class HouseEffectTest < ActiveSupport::TestCase
  def create_effect(pollster, **attributes)
    HouseEffect.create!({
      model_run: model_runs(:model_run_one), pollster: pollster,
      effect_raw: 2.0, effect_shrunk: 1.0, residual_count: 8, applied: true
    }.merge(attributes))
  end

  # The lookup is what the averager subtracts, so it must never contain an
  # effect the run decided not to act on.
  test "applied_lookup carries only the effects the run applied" do
    create_effect(pollsters(:beacon_polling), effect_shrunk: 1.25)
    create_effect(pollsters(:cardinal_research), effect_shrunk: -3.0, applied: false)

    lookup = HouseEffect.applied_lookup(model_runs(:model_run_one))

    assert_equal({ pollsters(:beacon_polling).id => 1.25 }, lookup)
  end

  test "applied_lookup is empty for a run with no effects, and for no run at all" do
    assert_empty HouseEffect.applied_lookup(model_runs(:model_run_one))
    assert_empty HouseEffect.applied_lookup(nil)
  end

  test "applied_lookup does not reach across runs" do
    other = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.day.ago)
    create_effect(pollsters(:beacon_polling), model_run: other, effect_shrunk: 9.0)

    assert_empty HouseEffect.applied_lookup(model_runs(:model_run_one))
    assert_equal({ pollsters(:beacon_polling).id => 9.0 }, HouseEffect.applied_lookup(other))
  end

  test "by_magnitude sorts on the size of the shrunk effect, whichever way it leans" do
    create_effect(pollsters(:beacon_polling), effect_shrunk: 0.5)
    create_effect(pollsters(:cardinal_research), effect_shrunk: -2.5)
    create_effect(pollsters(:delta_metrics), effect_shrunk: 1.5)

    assert_equal [ -2.5, 1.5, 0.5 ], HouseEffect.by_magnitude.pluck(:effect_shrunk)
  end

  test "a residual count cannot be negative" do
    effect = HouseEffect.new(model_run: model_runs(:model_run_one), pollster: pollsters(:beacon_polling),
                             effect_raw: 1.0, effect_shrunk: 1.0, residual_count: -1)

    assert_not effect.valid?
    assert_includes effect.errors.attribute_names, :residual_count
  end

  test "effects go away with the run that produced them" do
    # A run of its own: the fixture run carries dispatches, which the database
    # holds a foreign key on, so destroying it tests somebody else's rule.
    run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.day.ago)
    create_effect(pollsters(:beacon_polling), model_run: run)

    assert_difference "HouseEffect.count", -1 do
      run.destroy
    end
  end
end
