require "test_helper"

class RailsMindWorkflowTest < ActionDispatch::IntegrationTest
  class MemoryCollector
    attr_reader :events

    def initialize = @events = []
    def push(event) = (@events << event; true)
  end

  setup do
    @previous_client = RailsMind.client
    @collector = MemoryCollector.new
    # Exercise the real SDK locally; no credential, collector thread or HTTP.
    RailsMind.client = RailsMind::Client.new(RailsMind::Configuration.new(env: {}), collector: @collector)
    @subscriber = Subscriber.subscribe!(email_address: "workflow-pilot@example.com")
  end

  teardown do
    RailsMind.client = @previous_client
    RailsMind::Context.current.clear
  end

  test "preferences request is linked through queued mail without exporting private content" do
    post email_preferences_path, params: { subscriber: { email_address: @subscriber.email_address } }

    assert_redirected_to email_preferences_path
    request = @collector.events.find { |event| event["name"] == "SubscriptionPreferencesController#create" }
    queued = enqueued_jobs.find { |job| job[:job] == ActionMailer::MailDeliveryJob }
    assert request
    assert queued
    assert_match(/\A[0-9a-f]{32}\z/, request["trace_id"])

    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob)

    enqueue = workflow_events("active_job", "enqueue").sole
    started = workflow_events("active_job", "perform_start").sole
    rendered = workflow_events("action_mailer", "process").sole
    attempted = workflow_events("action_mailer", "delivery_attempt_completed").sole
    [ enqueue, started, rendered, attempted ].each do |event|
      assert_equal request["trace_id"], event["trace_id"]
      assert_equal queued["job_id"], event["job_id"]
    end
    assert_equal 1, ActionMailer::Base.deliveries.count { |message| message.to == [ @subscriber.email_address ] }
    assert_private_content_omitted(@subscriber.email_address, @subscriber.unsubscribe_token,
      "Manage your 535 dispatch emails")
    assert_empty RailsMind::Context.snapshot
  end

  test "rendering dispatch content for the direct provider client is not a delivery attempt" do
    delivery = DispatchDelivery.create!(dispatch: dispatches(:maine_poll_reaction),
      subscriber: @subscriber, to_address: @subscriber.email_address)

    message = DispatchMailer.with(delivery: delivery).dispatch_update
    assert message.html_part

    assert_equal 1, workflow_events("action_mailer", "process").size
    assert_empty workflow_events("action_mailer", "delivery_attempt_completed")
    assert_empty workflow_events("action_mailer", "delivery_not_observed")
    assert_private_content_omitted(@subscriber.email_address, @subscriber.unsubscribe_token,
      delivery.dispatch.headline)
  end

  private
    def workflow_events(instrumentation, operation)
      @collector.events.select do |event|
        event.dig("properties", "instrumentation") == instrumentation &&
          event.dig("properties", "operation") == operation
      end
    end

    def assert_private_content_omitted(*values)
      json = @collector.events.to_json
      values.each { |value| assert_not_includes json, value }
      @collector.events.each do |event|
        assert_empty event.fetch("properties").keys &
          %w[to from recipients subject body mail args arguments params attachments headers]
      end
    end
end
