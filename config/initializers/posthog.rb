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

posthog_token = Rails.application.credentials.posthog_project_token unless Rails.env.test?
Rails.configuration.x.posthog_project_token = posthog_token

if posthog_token.blank? && Rails.env.development?
  Rails.logger.warn(
    "The posthog_project_token Rails credential required by PostHog is " \
    "missing or unconfigured, which causes events to be silently missed. " \
    "This warning stops appearing once the credential is configured."
  )
end

PostHog.init do |config|
  config.api_key = posthog_token
  config.host = ENV.fetch("POSTHOG_HOST", "https://us.i.posthog.com")
end

# Report an exception as a PostHog issue only from a long-running process that
# serves real traffic or runs real jobs. A `bin/rails console`, a `bin/rails
# runner` one-liner, or a rake task is an operator session: an exception there
# is a typo, not a production incident. Such an exception used to open an issue
# that then competed with real errors for triage, so this gate keeps those
# sessions quiet. Every other PostHog feature stays on.
module PostHogExceptionCapture
  module_function

  # @param program_name [String] the running process name, `$PROGRAM_NAME`.
  # @return [Boolean] whether this process reports exceptions to PostHog.
  def wanted_in?(program_name = $PROGRAM_NAME)
    # `bin/rails server` builds a Rails::Server before it boots the app, so the
    # constant is already defined when this initializer runs. Production runs
    # the server behind Thruster and development runs it through bin/dev; both
    # go through this command.
    return true if defined?(::Rails::Server)

    # The dedicated worker starts as `bundle exec good_job start`, so its
    # executable is the process name.
    return true if program_name.end_with?("good_job")

    false
  end
end

PostHog::Rails.configure do |config|
  # Capture exceptions only from the web server and the job worker (see
  # PostHogExceptionCapture above), never from a console, runner, or rake
  # session.
  capture_exceptions = PostHogExceptionCapture.wanted_in?

  # Auto-capture unhandled exceptions in controllers, and the exceptions the
  # Rails error reporter forwards.
  config.auto_capture_exceptions = capture_exceptions

  # Also capture exceptions that Rails rescues (e.g. ActiveRecord::RecordNotFound)
  config.report_rescued_exceptions = capture_exceptions

  # Auto-instrument ActiveJob failures
  config.auto_instrument_active_job = true

  # Automatically associate errors with the current user
  config.capture_user_context = true
  config.current_user_method = :current_user
  config.user_id_method = :posthog_distinct_id
end
