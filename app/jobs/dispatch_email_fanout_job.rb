class DispatchEmailFanoutJob < ApplicationJob
  queue_as :mailers

  def perform(dispatch_id)
    return unless DispatchEmail.enabled?

    dispatch = Dispatch.published.find_by(id: dispatch_id)
    return unless dispatch

    Subscriber.subscribed.find_each do |subscriber|
      delivery = DispatchDelivery.create_or_find_by!(dispatch: dispatch, subscriber: subscriber) do |record|
        record.to_address = subscriber.email_address
      end

      SendDispatchEmailJob.perform_later(delivery.id) unless delivery.terminal?
    end
  end
end
