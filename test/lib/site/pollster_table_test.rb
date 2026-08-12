require "test_helper"

class Site::PollsterTableTest < ActiveSupport::TestCase
  setup { @run = model_runs(:model_run_one) }

  def create_effect(pollster, **attributes)
    HouseEffect.create!({
      model_run: @run, pollster: pollster,
      effect_raw: 2.0, effect_shrunk: 1.0, residual_count: 8, applied: true
    }.merge(attributes))
  end

  test "a pollster with no polls at all is not on the page" do
    silent = create_pollster("Never Published Anything")

    rows = Site::PollsterTable.build(model_run: @run)

    assert_not_includes rows.map { |row| row.pollster.id }, silent.id
    assert_equal Poll.distinct.count(:pollster_id), rows.size
  end

  test "a row carries its poll count, its residual count and its effect" do
    create_effect(pollsters(:beacon_polling), effect_raw: 4.0, effect_shrunk: 2.5, residual_count: 11)

    row = Site::PollsterTable.build(model_run: @run).find { |r| r.pollster == pollsters(:beacon_polling) }

    assert_predicate row, :estimated?
    assert_predicate row, :applied?
    assert_equal 1, row.poll_count
    assert_equal 11, row.residual_count
    assert_in_delta 4.0, row.effect.effect_raw, 1e-9
    assert_in_delta 2.5, row.magnitude, 1e-9
  end

  # An unestimated pollster is not a pollster with an effect of zero, and the
  # row has to be able to say which — otherwise the page publishes 71 firms
  # as "no lean detected" when the truth is "never measured".
  test "a pollster with no effect row is unestimated rather than zero" do
    row = Site::PollsterTable.build(model_run: @run).find { |r| r.pollster == pollsters(:beacon_polling) }

    assert_not row.estimated?
    assert_not row.applied?
    assert_equal 0, row.residual_count
    assert_nil row.effect
  end

  test "rows sort by effect magnitude, then by poll count, with the unestimated last" do
    create_effect(pollsters(:cardinal_research), effect_shrunk: -2.0)
    create_effect(pollsters(:delta_metrics), effect_shrunk: 0.5)

    rows = Site::PollsterTable.build(model_run: @run)

    assert_equal [ "Cardinal Research", "Delta Metrics", "Beacon Polling" ], rows.map { |row| row.pollster.name }
    assert_not rows.last.estimated?
  end

  test "with no run there are still rows, and none of them claims an estimate" do
    create_effect(pollsters(:beacon_polling))

    rows = Site::PollsterTable.build(model_run: nil)

    assert_equal Poll.distinct.count(:pollster_id), rows.size
    assert_empty rows.select(&:estimated?)
  end

  test "an effect from another run does not leak into this one's table" do
    other = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: 1.day.ago)
    create_effect(pollsters(:beacon_polling), model_run: other)

    rows = Site::PollsterTable.build(model_run: @run)

    assert_empty rows.select(&:estimated?)
  end

  test "with no polls in the corpus the table is empty rather than a list of nobody" do
    Poll.destroy_all

    assert_empty Site::PollsterTable.build(model_run: @run)
  end
end
