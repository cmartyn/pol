# Model selection and OpenRouter wiring (API key, base URL, model slugs) are
# configured in Phase 5 (agent newsroom). This just opts into RubyLLM's
# current association-based acts_as API so boot doesn't emit the legacy-API
# deprecation warning on every load.
RubyLLM.configure do |config|
  config.use_new_acts_as = true
end
