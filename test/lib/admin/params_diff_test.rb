require "test_helper"

class Admin::ParamsDiffTest < ActiveSupport::TestCase
  test "flatten turns nested hashes into dot-notation keys" do
    flat = Admin::ParamsDiff.flatten({ "a" => 1, "b" => { "c" => 2, "d" => { "e" => 3 } } })
    assert_equal({ "a" => 1, "b.c" => 2, "b.d.e" => 3 }, flat)
  end

  test "a key present in both with the same value is neither added, removed, nor changed" do
    diff = Admin::ParamsDiff.call(current: { "n_sims" => 10_000 }, previous: { "n_sims" => 10_000 })
    assert_empty diff[:added]
    assert_empty diff[:removed]
    assert_empty diff[:changed]
  end

  test "a key only in current is added" do
    diff = Admin::ParamsDiff.call(current: { "n_sims" => 10_000 }, previous: {})
    assert_equal [ "n_sims" ], diff[:added].map(&:key)
    assert_equal 10_000, diff[:added].first.after
    assert_nil diff[:added].first.before
  end

  test "a key only in previous is removed" do
    diff = Admin::ParamsDiff.call(current: {}, previous: { "n_sims" => 10_000 })
    assert_equal [ "n_sims" ], diff[:removed].map(&:key)
    assert_equal 10_000, diff[:removed].first.before
    assert_nil diff[:removed].first.after
  end

  test "a key in both with a different value is changed, old to new" do
    diff = Admin::ParamsDiff.call(current: { "half_life_days" => 21 }, previous: { "half_life_days" => 14 })
    assert_equal [ "half_life_days" ], diff[:changed].map(&:key)
    assert_equal 14, diff[:changed].first.before
    assert_equal 21, diff[:changed].first.after
  end

  test "nested keys are compared in flat dot notation" do
    diff = Admin::ParamsDiff.call(
      current: { "averaging" => { "half_life_days" => 21 } },
      previous: { "averaging" => { "half_life_days" => 14 } }
    )
    assert_equal [ "averaging.half_life_days" ], diff[:changed].map(&:key)
  end

  test "results are sorted by key for a stable display order" do
    diff = Admin::ParamsDiff.call(current: { "z" => 1, "a" => 2 }, previous: {})
    assert_equal [ "a", "z" ], diff[:added].map(&:key)
  end

  test "nil snapshots are treated as empty rather than raising" do
    diff = Admin::ParamsDiff.call(current: { "n_sims" => 10_000 }, previous: nil)
    assert_equal [ "n_sims" ], diff[:added].map(&:key)

    diff = Admin::ParamsDiff.call(current: nil, previous: nil)
    assert_empty diff[:added]
    assert_empty diff[:removed]
    assert_empty diff[:changed]
  end

  test "the run-computed internals estimate never shows up as a param change" do
    base = { "averaging" => { "window_days" => 45 } }
    current = base.merge("internals_estimate" => { "shift" => 3.31, "pair_count" => 4 })
    previous = base.merge("internals_estimate" => { "shift" => 3.27, "pair_count" => 3 })

    diff = Admin::ParamsDiff.call(current: current, previous: previous)

    assert_empty diff[:added]
    assert_empty diff[:removed]
    assert_empty diff[:changed]
  end
end
