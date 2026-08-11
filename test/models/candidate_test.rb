require "test_helper"

class CandidateTest < ActiveSupport::TestCase
  test "party enum round-trips every value" do
    Candidate.parties.each_key do |value|
      candidate = Candidate.new(party: value)
      assert_equal value, candidate.party
    end
  end

  test "caucus_with enum round-trips every value with the caucus_with_ prefix" do
    Candidate.caucus_withs.each_key do |value|
      candidate = Candidate.new(caucus_with: value)
      assert_equal value, candidate.caucus_with
      assert candidate.public_send("caucus_with_#{value}?")
    end
  end

  test "caucus_with is nil by default" do
    assert_nil Candidate.new.caucus_with
  end

  test "belongs to a race" do
    assert_equal races(:senate_maine), candidates(:maine_dem).race
  end

  test "requires a name" do
    candidate = Candidate.new(race: races(:senate_maine), party: :dem)
    assert_not candidate.valid?
    assert_includes candidate.errors[:name], "can't be blank"
  end
end
