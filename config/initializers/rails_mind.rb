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

  # Page views: each HTML page a controller renders for a person is counted.
  # The first-party _rails_mind_visitor cookie is never set on a page
  # EdgeCacheable marks public, so those pages stay cacheable; pages Cloudflare
  # serves from its cache never reach the app and are not counted.
  # config.page_views = false # Count no page views.
  # config.visitor_cookie = false # Count visitors by a daily hash instead of a cookie.

  # Unsubscribe and password-reset links carry their secret in the path, where
  # filter_parameters cannot reach it, and a page view sends its path and the
  # path of the page the reader came from. Mask that segment in both.
  secret_in_path = %r{(?<=/unsubscribe/)[^/?#]+|(?<=/passwords/)(?!new(?:[/?#]|\z))[^/?#]+}
  config.before_send = lambda do |event|
    properties = event["properties"]
    if event["kind"] == "pageview" && properties.is_a?(Hash)
      %w[path referrer].each do |key|
        properties[key] = properties[key].gsub(secret_in_path, "[FILTERED]") if properties[key].is_a?(String)
      end
    end
    event
  end
end

# No existing Flipper adapter or OpenTelemetry provider is changed.
# Run `bin/rails rails_mind:doctor` and follow docs/sdk.md for opt-in integrations.
