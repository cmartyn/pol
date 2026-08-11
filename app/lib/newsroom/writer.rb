module Newsroom
  # One service, three kinds of dispatch. Build the payload, ask the model,
  # validate what comes back, and either publish it or record why not.
  #
  # The contract this class exists to keep: nothing invalid is ever published.
  # A draft that fails validation gets exactly one more turn — the same
  # conversation, with the validator's own complaints appended — and a second
  # failure ends in a newsroom_skips row and no dispatch. The same is true of
  # an API failure. The caller (a job) never has to handle an exception to keep
  # the rest of its races moving.
  class Writer
    Result = Struct.new(:dispatch, :skip, keyword_init: true) do
      def published? = dispatch.present?
    end

    ATTEMPTS = 2

    def self.call(...)
      new(...).call
    end

    # kind: :poll_reaction / :movement_note / :daily_brief
    # payload: a Newsroom::Context hash
    # model_key: which slug in config/model_params.yml writes this piece
    def initialize(kind:, payload:, race: nil, model_run: nil, model_key: nil, logger: Rails.logger)
      @kind = kind.to_sym
      @payload = payload
      @race = race
      @model_run = model_run
      @model_key = model_key || (@kind == :daily_brief ? :brief_model : :writer_model)
      @logger = logger
    end

    attr_reader :kind, :payload, :race, :model_run, :model_key, :logger

    def call
      client = Client.new(model_key, instructions: Prompts.system_prompt(kind), schema: Prompts::SCHEMA)
      errors = nil

      ATTEMPTS.times do |attempt|
        reply = client.ask(attempt.zero? ? Prompts.user_message(payload) : Prompts.retry_message(errors))
        errors = Validation.call(reply.data, kind: kind, citable_poll_ids: citable_poll_ids)

        return published(reply) if errors.empty?

        logger.warn("Newsroom::Writer: #{kind} draft #{attempt + 1} rejected — #{errors.join('; ')}")
      end

      skipped(:validation_failed, "rejected #{ATTEMPTS} drafts — #{errors.join('; ')}")
    rescue Client::Error => error
      skipped(:llm_error, error.message)
    end

    private
      def citable_poll_ids
        Array(payload[:citable_poll_ids])
      end

      def published(reply)
        dispatch = Dispatch.create!(
          kind: kind,
          race: race,
          model_run: model_run,
          headline: reply.data.fetch("headline").strip,
          dek: reply.data.fetch("dek").strip,
          body_markdown: reply.data.fetch("body_markdown").strip,
          cited_poll_ids: reply.data.fetch("cited_poll_ids").map(&:to_i),
          # The model that actually served the request, as OpenRouter reported
          # it — this is what the byline says, so it must not be the slug we
          # asked for if the two ever differ.
          model_slug: reply.model_id,
          status: :published,
          published_at: Time.current
        )

        logger.info(
          "Newsroom::Writer: published #{kind} ##{dispatch.id} " \
          "#{race ? "for #{race.slug} " : ""}via #{reply.model_id} " \
          "(#{reply.input_tokens.to_i} in / #{reply.output_tokens.to_i} out tokens)"
        )

        Result.new(dispatch: dispatch)
      end

      def skipped(reason, detail)
        Result.new(skip: NewsroomSkip.record!(
          kind: kind, race: race, reason: reason, detail: detail, payload: payload, logger: logger
        ))
      end
  end
end
