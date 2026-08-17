require "test_helper"

class Newsroom::ValidationTest < ActiveSupport::TestCase
  GOOD_BODY = "Two July surveys arrived this week.\n\nOur model gives the Democrat a 62 in 100 chance.".freeze

  # validate(headline: "...") — a draft that is fine except for what's passed.
  # kind_of/citable_ids are the two dials that aren't fields of the draft.
  def validate(kind_of: :poll_reaction, citable_ids: [ 11, 12 ], **overrides)
    data = {
      "headline" => "Maine Senate race tightens after two July surveys",
      "dek" => "Our average moves half a point; our model barely notices.",
      "body_markdown" => GOOD_BODY,
      "cited_poll_ids" => [ 11 ]
    }.merge(overrides.stringify_keys)

    Newsroom::Validation.call(data, kind: kind_of, citable_poll_ids: citable_ids)
  end

  test "a well-formed draft has nothing wrong with it" do
    assert_empty validate
  end

  test "anything that is not a JSON object is rejected outright" do
    [ nil, "prose, not JSON", [ 1, 2 ] ].each do |data|
      errors = Newsroom::Validation.call(data, kind: :daily_brief, citable_poll_ids: [])

      assert_equal 1, errors.size
      assert_match(/not a JSON object/, errors.sole)
    end
  end

  test "a missing field is a rejection, not a nil in the database" do
    assert_match(/headline is missing/, validate(headline: "").sole)
    assert_match(/dek is missing/, validate(dek: nil).sole)
    assert_match(/body_markdown is missing/, validate(body_markdown: "   ").sole)
  end

  test "the headline cap is the one in model_params.yml" do
    limit = Pol::Params.fetch!(:newsroom, :headline_max_chars)

    assert_empty validate(headline: "H" * limit)
    error = validate(headline: "H" * (limit + 1)).sole
    assert_match(/headline is #{limit + 1} characters; the limit is #{limit}/, error)
  end

  test "the dek cap is the one in model_params.yml" do
    limit = Pol::Params.fetch!(:newsroom, :dek_max_chars)

    assert_empty validate(dek: "D" * limit)
    assert_match(/the limit is #{limit}/, validate(dek: "D" * (limit + 1)).sole)
  end

  test "the body backstop is the one in model_params.yml, and it is words not characters" do
    limit = Pol::Params.fetch!(:newsroom, :body_words_backstop)

    assert_empty validate(body_markdown: ([ "word" ] * limit).join(" "))
    over = validate(body_markdown: ([ "word" ] * (limit + 1)).join(" ")).sole
    assert_match(/body_markdown is #{limit + 1} words/, over)
  end

  # The failure this backstop was widened for: a brief came back 472 words
  # against a 450-word gate, was rejected twice, and published nothing at all.
  # Length is house style, not a truth claim — a piece that runs a little long
  # beats a morning with no brief on it.
  test "a draft that overruns its kind's word target is still published" do
    Newsroom::Prompts::BODY_WORD_TARGETS.each do |kind, target|
      words = target + 100

      assert_empty validate(kind_of: kind, body_markdown: ([ "word" ] * words).join(" ")),
                   "a #{kind} of #{words} words, against a #{target}-word target, should still publish"
    end
  end

  # What stops the backstop being quietly re-tightened into a style rule again.
  test "the backstop sits clear of every word target, so only runaway output reaches it" do
    backstop = Pol::Params.fetch!(:newsroom, :body_words_backstop)

    Newsroom::Prompts::BODY_WORD_TARGETS.each do |kind, target|
      assert_operator backstop, :>=, 2 * target, "the backstop should leave a #{kind} real room to overrun"
    end
  end

  test "moving a cap in the params file moves the validator with it" do
    with_params(newsroom: { headline_max_chars: 10 }) do
      assert_match(/the limit is 10/, validate(headline: "This headline is longer than ten").sole)
    end
  end

  # The site renders body_markdown with simple_format, which does paragraphs
  # and nothing else, so structure would publish as literal punctuation.
  {
    "a markdown heading" => "## What the polls say\n\nBeacon has it close.",
    "a bullet list" => "The state of play:\n\n- Beacon: D+3.5\n- Cardinal: D+1.0",
    "a numbered list" => "Two things happened.\n\n1. Beacon polled the race.",
    "a block quote" => "Our model is unmoved.\n\n> A quote we did not have.",
    "a code fence" => "Here are the numbers.\n\n```\nD+3.5\n```",
    "a table row" => "The averages:\n\n| Pollster | Margin |\n| --- | --- |"
  }.each do |description, body|
    test "a body containing #{description} is rejected" do
      error = validate(body_markdown: body).sole

      assert_match(/#{description}/, error)
      assert_match(/plain paragraphs only/, error)
    end
  end

  test "a hyphen inside a sentence is not a bullet list" do
    assert_empty validate(body_markdown: "The margin - three and a half points - is inside the error.")
  end

  test "citing a poll that is not in the payload rejects the draft" do
    error = validate(cited_poll_ids: [ 11, 99 ]).sole

    assert_match(/\[99\]/, error)
    assert_match(/not in citable_poll_ids/, error)
  end

  test "citing every payload poll is fine" do
    assert_empty validate(cited_poll_ids: [ 11, 12 ])
  end

  test "cited_poll_ids has to be a list of ids" do
    assert_match(/must be an array/, validate(cited_poll_ids: "11").sole)
    assert_match(/not poll ids/, validate(cited_poll_ids: [ "the Beacon poll" ]).join(" "))
  end

  test "an id that arrives as a numeric string is still an id" do
    assert_empty validate(cited_poll_ids: [ "11" ])
  end

  test "a poll reaction that cites none of the polls it is reacting to is rejected" do
    assert_match(/must cite at least one/, validate(kind_of: :poll_reaction, cited_poll_ids: []).sole)
  end

  test "a brief may cite nothing, because it can be all model numbers" do
    assert_empty validate(kind_of: :daily_brief, citable_ids: [ 11 ], cited_poll_ids: [])
  end

  test "a poll reaction with no citable polls at all is not held to the citation rule" do
    assert_empty validate(kind_of: :poll_reaction, citable_ids: [], cited_poll_ids: [])
  end

  test "every problem with a bad draft is reported at once, so the retry can fix them together" do
    errors = validate(
      headline: "H" * 200,
      dek: "D" * 400,
      body_markdown: "## Heading\n\nThe body.",
      cited_poll_ids: [ 404 ]
    )

    assert_equal 4, errors.size
  end
end
