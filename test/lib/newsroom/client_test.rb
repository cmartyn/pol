require "test_helper"

class Newsroom::ClientTest < ActiveSupport::TestCase
  SCHEMA = Newsroom::Prompts::SCHEMA
  DRAFT = { headline: "A headline", dek: "A dek", body_markdown: "A body.", cited_poll_ids: [ 3 ] }.freeze

  def build_client(model_key = :writer_model)
    Newsroom::Client.new(model_key, instructions: "Be sober and numerate.", schema: SCHEMA)
  end

  test "configured? follows the OpenRouter key" do
    with_api_key { assert_predicate Newsroom::Client, :configured? }
    without_api_key { refute_predicate Newsroom::Client, :configured? }
  end

  test "the request carries the params model slug, the max-tokens bound and an auth header" do
    stub_openrouter(DRAFT)

    with_api_key do
      recording_openrouter do |requests|
        build_client.ask("write something")

        request = requests.sole
        assert_equal Pol::Params.fetch!(:newsroom, :writer_model), request[:body]["model"]
        assert_equal Pol::Params.fetch!(:newsroom, :max_output_tokens), request[:body]["max_tokens"]
        # Presence, never the value: a test that asserts the key is a test that
        # prints the key when it fails.
        assert request[:headers]["Authorization"].present?
        assert_match(/\ABearer \S/, request[:headers]["Authorization"])
      end
    end
  end

  test "the brief_model key selects the other slug" do
    stub_openrouter(DRAFT)

    with_api_key do
      recording_openrouter do |requests|
        build_client(:brief_model).ask("write something")

        assert_equal Pol::Params.fetch!(:newsroom, :brief_model), requests.sole[:body]["model"]
      end
    end
  end

  test "a model swap in model_params.yml is the only change a model swap needs" do
    stub_openrouter(DRAFT)

    with_params(newsroom: { writer_model: "some-vendor/some-model-9" }) do
      with_api_key do
        recording_openrouter do |requests|
          build_client.ask("write something")

          assert_equal "some-vendor/some-model-9", requests.sole[:body]["model"]
        end
      end
    end
  end

  test "the schema is sent as a strict json_schema response format" do
    stub_openrouter(DRAFT)

    with_api_key do
      recording_openrouter do |requests|
        build_client.ask("write something")

        format = requests.sole[:body]["response_format"]
        assert_equal "json_schema", format["type"]
        assert_equal "dispatch", format.dig("json_schema", "name")
        assert format.dig("json_schema", "strict")
        assert_equal %w[headline dek body_markdown cited_poll_ids],
                     format.dig("json_schema", "schema", "required")
      end
    end
  end

  test "the system instructions lead the conversation" do
    stub_openrouter(DRAFT)

    with_api_key do
      recording_openrouter do |requests|
        build_client.ask("write something")

        messages = requests.sole[:body]["messages"]
        assert_equal "Be sober and numerate.", messages.first["content"]
        assert_equal "write something", messages.last["content"]
      end
    end
  end

  test "structured output comes back parsed, with the model that actually served it" do
    stub_openrouter(DRAFT, model: "anthropic/claude-sonnet-5-20260630")

    with_api_key do
      reply = build_client.ask("write something")

      assert_equal "A headline", reply.data["headline"]
      assert_equal [ 3 ], reply.data["cited_poll_ids"]
      assert_equal "anthropic/claude-sonnet-5-20260630", reply.model_id
      assert_equal 1200, reply.input_tokens
      assert_equal 320, reply.output_tokens
    end
  end

  test "the configured slug is the byline of last resort when the response names no model" do
    body = completion_response(content: DRAFT).except(:model)
    stub_request(:post, NewsroomStubHelper::COMPLETIONS_URL)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(body))

    with_api_key do
      assert_equal Pol::Params.fetch!(:newsroom, :writer_model), build_client.ask("write something").model_id
    end
  end

  test "a reply that is not JSON is data the validator can reject, not an exception" do
    stub_openrouter("I would rather write this as an essay.")

    with_api_key do
      reply = build_client.ask("write something")

      assert_nil reply.data
      assert_equal "I would rather write this as an essay.", reply.text
    end
  end

  test "the conversation is kept, so a second ask is a follow-up" do
    stub_openrouter(DRAFT, DRAFT)

    with_api_key do
      recording_openrouter do |requests|
        client = build_client
        client.ask("first turn")
        client.ask("second turn")

        assert_equal 2, requests.size
        assert_equal 2, client.turns
        roles = requests.last[:body]["messages"].map { |message| message["role"] }
        assert_equal %w[system user assistant user], roles
        assert_equal "second turn", requests.last[:body]["messages"].last["content"]
      end
    end
  end

  # Whatever the provider does, the caller sees one error class carrying a
  # message that is safe to store in newsroom_skips.
  {
    "a rate limit" => 429,
    "a server error" => 500,
    "a gateway failure" => 503,
    "a rejected key" => 401
  }.each do |description, status|
    test "#{description} becomes a Newsroom::Client::Error" do
      stub_openrouter_error(status: status)

      with_api_key do
        without_llm_retries do
          error = assert_raises(Newsroom::Client::Error) { build_client.ask("write something") }
          assert_match(/RubyLLM::\w+Error/, error.message)
        end
      end
    end
  end

  test "a timeout becomes a Newsroom::Client::Error" do
    stub_request(:post, NewsroomStubHelper::COMPLETIONS_URL).to_timeout

    with_api_key do
      without_llm_retries do
        assert_raises(Newsroom::Client::Error) { build_client.ask("write something") }
      end
    end
  end

  test "a missing key fails as a Client::Error rather than taking the job down" do
    without_api_key do
      assert_raises(Newsroom::Client::Error) { build_client.ask("write something") }
    end
    assert_not_requested(:post, NewsroomStubHelper::COMPLETIONS_URL)
  end

  test "sanitize strips the key out of anything on its way to the skip log" do
    with_api_key("super-secret-key") do
      sanitized = Newsroom::Client.sanitize("RubyLLM::UnauthorizedError: super-secret-key was rejected")

      refute_includes sanitized, "super-secret-key"
      assert_includes sanitized, "[REDACTED]"
    end
  end

  test "sanitize truncates so one runaway provider message cannot fill the table" do
    with_api_key do
      assert_operator Newsroom::Client.sanitize("x" * 5_000).length, :<=, Newsroom::Client::DETAIL_LIMIT
    end
  end
end
