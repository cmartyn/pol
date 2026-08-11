# Nothing in this suite is allowed to reach OpenRouter. Every newsroom test
# either stubs the completions endpoint with a fixture response or asserts that
# no request was made at all.
#
# The API key is forced to a known literal for the duration of each test
# (with_api_key) rather than read from credentials: the suite has to behave the
# same on a machine that has the real credential and on one that doesn't, and
# the no_api_key path needs a way to be genuinely keyless.
module NewsroomStubHelper
  COMPLETIONS_URL = "https://openrouter.ai/api/v1/chat/completions".freeze
  TEST_API_KEY = "test-openrouter-key-not-a-real-credential".freeze

  def with_api_key(key = TEST_API_KEY)
    previous = RubyLLM.config.openrouter_api_key
    RubyLLM.config.openrouter_api_key = key
    yield
  ensure
    RubyLLM.config.openrouter_api_key = previous
  end

  def without_api_key(&)
    with_api_key(nil, &)
  end

  # Faraday retries 429s, 5xxs and timeouts config.max_retries times with a
  # backoff sleep before the error reaches us. That behaviour belongs to the
  # gem; our tests are about what we do with the error once it arrives, so they
  # turn retries off and get their answer immediately.
  def without_llm_retries
    previous = RubyLLM.config.max_retries
    RubyLLM.config.max_retries = 0
    yield
  ensure
    RubyLLM.config.max_retries = previous
  end

  # One OpenRouter chat completion, shaped exactly as the live API returns it
  # (the fields Providers::OpenRouter::Chat#parse_completion_response reads).
  def completion_response(content:, model: "anthropic/claude-sonnet-5", input_tokens: 1200, output_tokens: 320)
    {
      id: "gen-#{SecureRandom.hex(6)}",
      object: "chat.completion",
      created: Time.current.to_i,
      model: model,
      choices: [
        { index: 0, finish_reason: "stop",
          message: { role: "assistant", content: content.is_a?(String) ? content : JSON.generate(content) } }
      ],
      usage: { prompt_tokens: input_tokens, completion_tokens: output_tokens,
               total_tokens: input_tokens + output_tokens }
    }
  end

  # A well-formed draft, overridable field by field.
  def dispatch_json(headline: "Maine Senate race tightens after two July surveys",
                    dek: "Our model gives the Democrat a 62 in 100 chance, little changed from last week.",
                    body: nil, cited_poll_ids: [])
    {
      headline: headline,
      dek: dek,
      body_markdown: body || default_body,
      cited_poll_ids: cited_poll_ids
    }
  end

  # Stubs the completions endpoint. Pass one hash for a single reply, or
  # several to answer successive turns in order.
  def stub_openrouter(*replies, model: "anthropic/claude-sonnet-5")
    responses = replies.map do |reply|
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(completion_response(content: reply, model: model)) }
    end

    stub_request(:post, COMPLETIONS_URL).to_return(*responses)
  end

  def stub_openrouter_error(status:, body: { error: { message: "upstream said no" } })
    stub_request(:post, COMPLETIONS_URL)
      .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: JSON.generate(body))
  end

  # recording_openrouter { |requests| ...; requests.first["model"] } — the
  # parsed request bodies OpenRouter received inside the block, in order.
  def recording_openrouter
    requests = []
    WebMock.after_request(real_requests_only: false) do |request, _response|
      requests << { headers: request.headers, body: JSON.parse(request.body.to_s) } if openrouter?(request)
    end

    yield requests
  ensure
    WebMock.reset_callbacks
  end

  def openrouter?(request)
    request.uri.to_s.start_with?("https://openrouter.ai") && request.body.present?
  end

  def default_body
    <<~BODY.strip
      Two July surveys of the Maine Senate race arrived this week, and neither moved our model much. Beacon
      Polling, fielding July 10-14 among 812 likely voters, put the Democrat ahead by three and a half points.

      Our average now has the race at D+3.2, and our model gives the Democrat a 62 in 100 chance of winning
      the seat. A lead that size is well inside the range where either candidate wins.
    BODY
  end
end
