require "test_helper"

class Newsroom::WriterTest < ActiveSupport::TestCase
  setup do
    @race = races(:senate_maine)
    @run = model_runs(:model_run_one)
    @polls = [ polls(:maine_poll_one), polls(:maine_poll_two) ]
    @payload = Newsroom::Context.poll_reaction(race: @race, polls: @polls, model_run: @run)
  end

  def write(kind: :poll_reaction, race: @race, payload: @payload)
    Newsroom::Writer.call(kind: kind, race: race, model_run: @run, payload: payload)
  end

  test "a valid draft is published, bylined with the model that served it" do
    stub_openrouter(dispatch_json(cited_poll_ids: @polls.map(&:id)), model: "anthropic/claude-sonnet-5-20260630")

    result = with_api_key { write }

    assert_predicate result, :published?
    dispatch = result.dispatch
    assert_predicate dispatch, :published?
    assert_predicate dispatch, :poll_reaction?
    assert_equal @race, dispatch.race
    assert_equal @run, dispatch.model_run
    assert_equal "anthropic/claude-sonnet-5-20260630", dispatch.model_slug
    assert_equal @polls.map(&:id).sort, dispatch.cited_poll_ids.sort
    assert dispatch.published_at.present?
    assert_empty NewsroomSkip.all
  end

  test "the brief is written by the brief model, the rest by the writer model" do
    stub_openrouter(dispatch_json(cited_poll_ids: []), dispatch_json(cited_poll_ids: []))

    with_api_key do
      recording_openrouter do |requests|
        Newsroom::Writer.call(kind: :daily_brief, model_run: @run, payload: { citable_poll_ids: [] })
        write(payload: { citable_poll_ids: [] })

        assert_equal Pol::Params.fetch!(:newsroom, :brief_model), requests.first[:body]["model"]
        assert_equal Pol::Params.fetch!(:newsroom, :writer_model), requests.last[:body]["model"]
      end
    end
  end

  test "a draft citing a poll that is not in the payload gets one more turn, with the reason" do
    good = dispatch_json(cited_poll_ids: @polls.map(&:id))
    over_cited = dispatch_json(cited_poll_ids: @polls.map(&:id) + [ 987_654 ])
    stub_openrouter(over_cited, good)

    result = with_api_key do
      recording_openrouter do |requests|
        outcome = write

        assert_equal 2, requests.size
        retry_turn = requests.last[:body]["messages"].last["content"]
        assert_match(/rejected by our validator/, retry_turn)
        assert_match(/987654/, retry_turn)
        assert_match(/not in citable_poll_ids/, retry_turn)
        outcome
      end
    end

    assert_predicate result, :published?
    assert_empty NewsroomSkip.all
  end

  test "two bad drafts publish nothing and leave a validation_failed skip" do
    over_cited = dispatch_json(cited_poll_ids: [ 987_654 ])
    stub_openrouter(over_cited, over_cited)

    result = nil
    assert_no_difference "Dispatch.count" do
      result = with_api_key { write }
    end

    refute_predicate result, :published?
    skip = result.skip
    assert_predicate skip, :validation_failed?
    assert_predicate skip, :poll_reaction?
    assert_equal @race, skip.race
    assert_match(/rejected 2 drafts/, skip.detail)
    assert_match(/987654/, skip.detail)
    assert_equal 64, skip.payload_digest.length
  end

  test "an over-long headline is our problem to catch, not the model's to be trusted with" do
    long = dispatch_json(headline: "H" * 200, cited_poll_ids: @polls.map(&:id))
    stub_openrouter(long, long)

    assert_no_difference "Dispatch.count" do
      with_api_key { write }
    end

    assert_match(/headline is 200 characters/, NewsroomSkip.sole.detail)
  end

  test "a body with markdown structure never reaches the page" do
    with_headings = dispatch_json(body: "## The polls\n\nBeacon had it close.", cited_poll_ids: @polls.map(&:id))
    stub_openrouter(with_headings, with_headings)

    assert_no_difference "Dispatch.count" do
      with_api_key { write }
    end

    assert_match(/markdown heading/, NewsroomSkip.sole.detail)
  end

  test "a reply that is not JSON at all is a validation failure, not a crash" do
    stub_openrouter("Here is my piece, in prose.", "Still prose, sorry.")

    assert_no_difference "Dispatch.count" do
      with_api_key { write }
    end

    assert_match(/not a JSON object/, NewsroomSkip.sole.detail)
  end

  test "an API failure is recorded as an llm_error skip and never re-raised" do
    stub_openrouter_error(status: 500)

    result = nil
    assert_no_difference "Dispatch.count" do
      with_api_key { without_llm_retries { result = write } }
    end

    assert_predicate result.skip, :llm_error?
    assert_match(/RubyLLM::ServerError/, result.skip.detail)
  end

  test "the API key cannot travel into the skip log" do
    stub_openrouter_error(status: 401, body: { error: { message: "key #{NewsroomStubHelper::TEST_API_KEY} rejected" } })

    with_api_key { without_llm_retries { write } }

    refute_includes NewsroomSkip.sole.detail, NewsroomStubHelper::TEST_API_KEY
    assert_includes NewsroomSkip.sole.detail, "[REDACTED]"
  end

  test "the payload is what the model is given, and the whole of what it is given" do
    stub_openrouter(dispatch_json(cited_poll_ids: @polls.map(&:id)))

    with_api_key do
      recording_openrouter do |requests|
        write

        messages = requests.sole[:body]["messages"]
        assert_equal "system", messages.first["role"]
        assert_match(/you have no other information/i, messages.first["content"])
        assert_match(/marginally firmer than a fuller model's/, messages.first["content"])
        # Phase 10 took out the mandate that every House sentence carry a
        # qualifier; what is left says the writer MAY say it, and where.
        refute_match(/must say/, messages.first["content"])
        # The gap the first live brief fell into: it wrote that Democrats had
        # a 96 in 100 chance of "holding" the House, which the payload never
        # said and which is not true.
        assert_match(/never holding, keeping, defending, losing or flipping/, messages.first["content"])
        # And the instruction not to price the difference, in place of the
        # measurement this prompt used to hardcode.
        assert_match(/Do not put a figure on the difference/, messages.first["content"])
        assert_match(/RETRACTED by editor/, messages.first["content"])
        assert_includes messages.last["content"], JSON.pretty_generate(@payload)
      end
    end
  end
end
