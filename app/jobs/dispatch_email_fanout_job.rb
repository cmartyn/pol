class DispatchEmailFanoutJob < ApplicationJob
  queue_as :mailers

  def perform(dispatch_id)
    return unless DispatchEmail.enabled?

    dispatch = Dispatch.published.find_by(id: dispatch_id)
    return unless dispatch

    enqueued = 0

    Subscriber.subscribed.find_each do |subscriber|
      delivery = DispatchDelivery.create_or_find_by!(dispatch: dispatch, subscriber: subscriber) do |record|
        record.to_address = subscriber.email_address
      end

      next if delivery.terminal?

      SendDispatchEmailJob.perform_later(delivery.id)
      enqueued += 1
    end

    return unless enqueued.positive?

    PostHog.capture(
      distinct_id: "newsroom",
      event: "dispatch_emails_queued",
      properties: {
        dispatch_id: dispatch.id,
        dispatch_kind: dispatch.kind,
        recipient_count: enqueued,
        "$process_person_profile" => false
      }
    )
  end
end
