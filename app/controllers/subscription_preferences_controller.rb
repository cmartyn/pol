class SubscriptionPreferencesController < PublicController
  rate_limit to: 5, within: 15.minutes, only: :create

  def show
  end

  def create
    unless params[:website].present?
      subscriber = Subscriber.find_by(email_address: normalized_email)
      SubscriberMailer.with(subscriber: subscriber).manage.deliver_later if subscriber&.subscribed?
    end

    redirect_to email_preferences_path,
                notice: "If that address is subscribed, a secure unsubscribe link is on its way.",
                status: :see_other
  end

  private
    def normalized_email
      Subscriber.normalize_value_for(:email_address, params.dig(:subscriber, :email_address))
    end
end
