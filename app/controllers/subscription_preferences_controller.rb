class SubscriptionPreferencesController < PublicController
  rate_limit to: 5, within: 15.minutes, only: :create

  def show
  end

  def create
    unless params[:website].present?
      subscriber = Subscriber.find_by(email_address: normalized_email)
      SubscriberMailer.with(subscriber: subscriber).manage.deliver_later if subscriber&.subscribed?
    end

    # Distinct id comes from the PostHog tracing header when the browser sends
    # one, so this lines up with that reader's pageviews. No header means a
    # personless event — a Rails session id would invent a second person.
    PostHog.capture(event: "email_preferences_requested")

    redirect_to email_preferences_path,
                notice: "If that address is subscribed, a secure unsubscribe link is on its way.",
                status: :see_other
  end

  private
    def normalized_email
      Subscriber.normalize_value_for(:email_address, params.dig(:subscriber, :email_address))
    end
end
