class SubscriberMailer < ApplicationMailer
  def manage
    @subscriber = params.fetch(:subscriber)
    @unsubscribe_url = unsubscribe_url(
      token: @subscriber.unsubscribe_token,
      host: ENV.fetch("CANONICAL_HOST", "535.wtf"),
      protocol: Rails.env.production? ? "https" : "http"
    )

    mail(to: @subscriber.email_address, subject: "Manage your 535 dispatch emails")
  end
end
