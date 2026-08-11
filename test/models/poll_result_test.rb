require "test_helper"

class PollResultTest < ActiveSupport::TestCase
  test "party enum round-trips every value" do
    PollResult.parties.each_key do |value|
      result = PollResult.new(party: value)
      assert_equal value, result.party
    end
  end

  test "pct must be within 0..100" do
    result = PollResult.new(poll: polls(:maine_poll_one), party: :dem, pct: -1)
    assert_not result.valid?

    result.pct = 101
    assert_not result.valid?

    result.pct = 0
    assert result.valid?

    result.pct = 100
    assert result.valid?
  end

  test "candidate is optional for generic-ballot results" do
    result = poll_results(:generic_ballot_dem)
    assert_nil result.candidate
    assert result.valid?
  end
end
