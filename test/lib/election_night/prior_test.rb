require "test_helper"

class ElectionNight::PriorTest < ActiveSupport::TestCase
  test "an old pre-election prior is explicitly disclosed without preventing development" do
    freshness = ElectionNight::Prior.freshness({ "as_of" => "2026-10-21T11:00:00Z" }, now: Time.iso8601("2026-11-03T18:00:00Z"))
    assert_equal true, freshness.fetch("prior_is_old")
    assert_in_delta 319, freshness.fetch("prior_age_hours"), 0.01
    assert_in_delta 324, freshness.fetch("prior_age_at_poll_close_hours"), 0.01
    assert_match(/13.5 days/, freshness.fetch("prior_warning"))
  end

  test "prior freshness is relative to election cutoff rather than the end of a prolonged count" do
    freshness = ElectionNight::Prior.freshness({ "as_of" => "2026-11-03T18:00:00Z" }, now: Time.iso8601("2026-11-07T18:00:00Z"))
    assert_equal false, freshness.fetch("prior_is_old")
    assert_equal 5.0, freshness.fetch("prior_age_at_poll_close_hours")
    assert_nil freshness.fetch("prior_warning")
  end

  test "future or post-cutoff forecasts cannot replace a frozen pre-election prior" do
    assert_raises(ArgumentError) do
      ElectionNight::Prior.freshness({ "as_of" => "2026-11-03T19:00:00Z" }, now: Time.iso8601("2026-11-03T18:00:00Z"))
    end
    assert_raises(ArgumentError) do
      ElectionNight::Prior.freshness({ "as_of" => "2026-11-04T01:00:00Z" }, now: Time.iso8601("2026-11-04T02:00:00Z"))
    end
  end
end
