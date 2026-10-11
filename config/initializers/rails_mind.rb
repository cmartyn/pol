RailsMind.configure do |config|
  # Clear inherited credentials in tests; test traffic must never reach production.
  config.token = Rails.env.test? ? nil : ENV["RAILS_MIND_KEY"]

  # Endpoint defaults to https://railsmind.com; RAILS_MIND_ENDPOINT overrides it.
  # Release is detected from hosting metadata or Rails.root/REVISION when available.
  # RAILS_MIND_RELEASE is an optional override. Neither variable is required.

  # Optional capabilities can be switched off independently.
  # config.apm = false
  # config.errors = false
  # config.analytics = false
  # config.flags = false

  # Scrubbed exception messages and literal-free repeated-query shapes are sent
  # by default. Disable either if the app needs a stricter collection policy.
  # config.capture_exception_message = false
  # config.capture_query_shapes = false
  # config.before_send = ->(event) { event } # Return nil to drop an event.
end

# No existing Ahoy store, Flipper adapter, or OpenTelemetry provider is changed.
# Run `bin/rails rails_mind:doctor` and follow docs/sdk.md for opt-in integrations.
