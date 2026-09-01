require "test_helper"

# PostHogExceptionCapture is defined in config/initializers/posthog.rb and
# decides which processes turn an exception into a PostHog issue.
class PostHogExceptionCaptureTest < ActiveSupport::TestCase
  test "the job worker process reports exceptions" do
    assert PostHogExceptionCapture.wanted_in?("/rails/bin/good_job")
  end

  test "a runner, console, or rake session does not report exceptions" do
    refute PostHogExceptionCapture.wanted_in?("/rails/bin/rails")
    refute PostHogExceptionCapture.wanted_in?("/usr/local/bin/rake")
  end

  test "the running test process has exception capture disabled" do
    # This suite runs through a rails command, the same operator family that
    # used to open issues, so both capture switches must be off here.
    refute PostHog::Rails.config.auto_capture_exceptions
    refute PostHog::Rails.config.report_rescued_exceptions
  end
end
