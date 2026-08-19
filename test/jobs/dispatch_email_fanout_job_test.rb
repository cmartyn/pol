require "test_helper"

class DispatchEmailFanoutJobTest < ActiveJob::TestCase
  setup do
    @old_enabled = ENV["DISPATCH_EMAILS_ENABLED"]
    ENV["DISPATCH_EMAILS_ENABLED"] = "true"
    @active = Subscriber.subscribe!(email_address: "active@example.com")
    @inactive = Subscriber.subscribe!(email_address: "inactive@example.com").tap(&:unsubscribe!)
  end

  teardown do
    ENV["DISPATCH_EMAILS_ENABLED"] = @old_enabled
  end

  test "a newly published dispatch enqueues fanout after commit" do
    assert_enqueued_with(job: DispatchEmailFanoutJob) do
      Dispatch.create!(
        headline: "Fresh dispatch", body_markdown: "Fresh body.", kind: :daily_brief,
        status: :published, published_at: Time.current
      )
    end
  end

  test "fanout snapshots only active subscribers and is idempotent" do
    dispatch = dispatches(:maine_poll_reaction)

    assert_enqueued_with(job: SendDispatchEmailJob) do
      DispatchEmailFanoutJob.perform_now(dispatch.id)
    end

    assert_equal [ @active.id ], DispatchDelivery.where(dispatch: dispatch).pluck(:subscriber_id)

    assert_no_difference "DispatchDelivery.count" do
      DispatchEmailFanoutJob.perform_now(dispatch.id)
    end
  end
end
