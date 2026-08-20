class SubscriptionsController < PublicController
  rate_limit to: 8, within: 3.minutes, only: :create

  def create
    if params[:website].present?
      return redirect_back fallback_location: root_path, notice: subscription_notice, status: :see_other
    end

    subscriber = Subscriber.subscribe!(
      email_address: subscriber_params[:email_address],
      source: params[:source]
    )

    # PostHog: Track email subscription (key conversion event)
    PostHog.capture(
      distinct_id: "subscriber:#{subscriber.id}",
      event: "subscriber_signed_up",
      properties: { source: params[:source].to_s.presence || "direct" }
    )

    redirect_back fallback_location: root_path, notice: subscription_notice, status: :see_other
  rescue ActiveRecord::RecordInvalid
    redirect_back fallback_location: root_path, alert: "Enter a valid email address.", status: :see_other
  end

  private
    def subscriber_params
      params.require(:subscriber).permit(:email_address)
    end

    def subscription_notice
      "You're subscribed. The next new dispatch will arrive by email."
    end
end
