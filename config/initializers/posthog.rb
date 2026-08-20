# PostHog analytics and error tracking initializer
#
# The posthog-rails gem provides:
# - Automatic exception capture for unhandled controller errors
# - ActiveJob instrumentation for background job failures
# - User context detection from current_user
# - Rails.error integration for rescued exceptions
#
# A missing token never breaks the app: PostHog.init is always called so
# the class-level capture/identify methods are always defined. With a nil
# api_key, posthog-ruby silently drops all events. In development the app
# logs a loud warning so you know events are being lost.

posthog_token = ENV.fetch("POSTHOG_PROJECT_TOKEN", nil)

if posthog_token.blank? && Rails.env.development?
  Rails.logger.warn(
    "POSTHOG_PROJECT_TOKEN variable required by PostHog is missing or " \
    "un-configured, this causes events to be silently missed. " \
    "This error stops appearing once POSTHOG_PROJECT_TOKEN is configured."
  )
end

PostHog.init do |config|
  config.api_key = posthog_token
  config.host = ENV.fetch("POSTHOG_HOST", "https://us.i.posthog.com")
end

PostHog::Rails.configure do |config|
  # Auto-capture unhandled exceptions in controllers
  config.auto_capture_exceptions = true

  # Also capture exceptions that Rails rescues (e.g. ActiveRecord::RecordNotFound)
  config.report_rescued_exceptions = true

  # Auto-instrument ActiveJob failures
  config.auto_instrument_active_job = true

  # Automatically associate errors with the current user
  config.capture_user_context = true
  config.current_user_method = :current_user
  config.user_id_method = :posthog_distinct_id
end
