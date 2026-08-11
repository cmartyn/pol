# Every LLM call this app makes goes through ruby_llm to OpenRouter, which is
# the only outbound AI dependency. The model slugs are not here — they live in
# config/model_params.yml (newsroom.writer_model / newsroom.brief_model) so a
# model swap is a one-string config change, not a code change.
RubyLLM.configure do |config|
  # Opt into RubyLLM's current association-based acts_as API so boot doesn't
  # emit the legacy-API deprecation warning on every load.
  config.use_new_acts_as = true

  # The credential is the source of truth; ENV is the escape hatch for a
  # container that has no master key. A missing key must NOT raise here:
  # boot has to succeed on a machine with no credentials at all (CI, a fresh
  # clone), and the newsroom jobs check for the key themselves and record a
  # no_api_key skip instead of failing. RubyLLM only raises about missing
  # configuration when a provider is actually instantiated.
  config.openrouter_api_key = Rails.application.credentials.openrouter_api_key || ENV["OPENROUTER_API_KEY"]

  # ruby_llm's OpenAI-compatible providers send system prompts under the
  # "developer" role unless told otherwise — OpenAI's newer name for it. We
  # talk to OpenRouter with an Anthropic model behind it, where "system" is the
  # role every provider in the chain understands, so ask for the plain one.
  config.openai_use_system_role = true

  # Without this, ruby_llm builds its own Logger on $stdout, which would put
  # Faraday's request logging in front of anything reading our output.
  config.logger = Rails.logger
end
