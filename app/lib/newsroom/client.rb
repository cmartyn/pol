module Newsroom
  # The whole of this app's contact with an LLM: one chat, against one
  # OpenRouter model, asking for one JSON object.
  #
  # ruby_llm 2.0 mechanics this leans on, all read out of the installed gem
  # rather than remembered:
  #   * `RubyLLM.chat(model:, provider: :openrouter, assume_model_exists: true)`
  #     skips the bundled model registry (which does not carry OpenRouter's
  #     catalogue) and goes straight to the provider — see Models.resolve.
  #   * `#with_schema(hash)` becomes OpenRouter's
  #     `response_format: {type: "json_schema", json_schema: {...}}`. The
  #     reply's JSON text is `message.content`; the parsed Hash is
  #     `message.parsed`.
  #   * `#with_provider_options(max_tokens:)` is merged into the request body,
  #     which is how the output bound gets applied.
  #   * The reply's `model` is OpenRouter's own `model` field — the model
  #     that actually served the request, which is what the byline should say.
  #     Token counts live on `message.tokens`.
  #   * Faraday maps HTTP failures to RubyLLM::Error subclasses
  #     (UnauthorizedError, RateLimitError, ServerError, ...) via
  #     ErrorMiddleware, and retries 429/5xx/timeouts config.max_retries times
  #     before they reach us.
  #
  # Deliberately not set: temperature. OpenRouter's model list shows the
  # current Anthropic Sonnet-tier model does not accept it, and ruby_llm only
  # sends the field when it has been asked to.
  class Client
    Reply = Struct.new(:data, :text, :model_id, :input_tokens, :output_tokens, keyword_init: true)

    # Every failure to get an answer out of the provider, flattened to one
    # class with a message that is safe to store: the writer turns this into
    # an llm_error skip rather than letting a job blow up.
    Error = Class.new(StandardError)

    PROVIDER = :openrouter
    DETAIL_LIMIT = 500

    class << self
      # False when no key is configured — the newsroom then skips with
      # no_api_key instead of raising. Reads RubyLLM's config rather than the
      # credential directly so there is one answer to "is this wired up?".
      def configured?
        RubyLLM.config.openrouter_api_key.present?
      end

      # Errors get stored in newsroom_skips and read by a human later, so the
      # key must not be able to travel in one — provider messages sometimes
      # echo request context back. Belt and braces: strip the key if it
      # appears, then truncate.
      def sanitize(message)
        text = message.to_s
        key = RubyLLM.config.openrouter_api_key
        text = text.gsub(key, "[REDACTED]") if key.present?
        text.truncate(DETAIL_LIMIT)
      end
    end

    # model_key is :writer_model or :brief_model — a key under `newsroom:` in
    # config/model_params.yml, so swapping models is a one-string edit.
    def initialize(model_key, instructions:, schema:)
      @model_key = model_key
      @slug = Pol::Params.fetch!(:newsroom, model_key)
      @instructions = instructions
      @schema = schema
    end

    attr_reader :slug

    # Sends one turn and returns a Reply. The chat is kept between calls, so a
    # second #ask is a follow-up in the same conversation — which is what makes
    # "here is what was wrong with your draft, try again" work.
    def ask(prompt)
      message = chat.ask(prompt)
      content = message.content

      Reply.new(
        data: parsed_hash(message),
        text: content.is_a?(String) ? content : nil,
        # Fall back to the configured slug: OpenRouter always reports the
        # serving model, but a byline is not worth an exception.
        model_id: message.model.presence || slug,
        input_tokens: message.tokens&.input,
        output_tokens: message.tokens&.output
      )
    rescue RubyLLM::Error, RubyLLM::ConfigurationError, Faraday::Error, Timeout::Error => error
      raise Error, self.class.sanitize("#{error.class}: #{error.message}")
    end

    # How many turns this conversation has taken — the retry test asserts on
    # the wire, but the writer logs this.
    def turns
      @chat ? @chat.messages.count { |message| message.role == :user } : 0
    end

    private
      def chat
        @chat ||= RubyLLM
          .chat(model: slug, provider: PROVIDER, assume_model_exists: true)
          .with_instructions(@instructions)
          .with_schema(@schema)
          .with_provider_options(max_tokens: Pol::Params.fetch!(:newsroom, :max_output_tokens))
      end

      # A model that ignores the schema and answers in prose is a validation
      # problem, not an exception: nil data flows into Newsroom::Validation,
      # which rejects it with a message the retry turn can act on.
      def parsed_hash(message)
        parsed = message.parsed
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
  end
end
