require "test_helper"

class Newsroom::PromptsTest < ActiveSupport::TestCase
  # The word count in the prompt is an editorial aim. Newsroom::Validation's
  # backstop sits far above it and exists only for runaway output, so the model
  # is never told that number: given a ceiling, it writes to the ceiling.
  test "each kind is aimed at its own word target, and never told the validator's backstop" do
    backstop = Pol::Params.fetch!(:newsroom, :body_words_backstop)

    Newsroom::Prompts::BODY_WORD_TARGETS.each do |kind, target|
      prompt = Newsroom::Prompts.system_prompt(kind)

      assert_match(/about #{target} words/, prompt, "a #{kind} should be aimed at #{target} words")
      refute_match(/#{backstop}/, prompt, "a #{kind} should not be told the #{backstop}-word backstop")
    end
  end

  # The brief covers both chambers, the generic ballot, the movers and recent
  # polling; a reaction covers one race. They had the same budget until the
  # brief started failing on it.
  test "the brief is given more room than a single-race piece, because it covers more ground" do
    targets = Newsroom::Prompts::BODY_WORD_TARGETS

    assert_operator targets.fetch(:daily_brief), :>, targets.fetch(:poll_reaction)
    assert_operator targets.fetch(:daily_brief), :>, targets.fetch(:movement_note)
  end

  test "every kind the writer can be asked for has a target" do
    assert_equal Newsroom::Prompts::ASSIGNMENTS.keys.sort, Newsroom::Prompts::BODY_WORD_TARGETS.keys.sort
  end
end
