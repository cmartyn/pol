class SubscriptionsController < PublicController
  without_csrf_token

  rate_limit to: 8, within: 3.minutes, only: :create

  before_action :set_form_context, only: :create

  def create
    if params[:website].present?
      return confirm_subscription
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

    confirm_subscription
  rescue ActiveRecord::RecordInvalid
    reject_subscription
  end

  private
    # Which of the page's two form copies was submitted, so the turbo_stream
    # response replaces that one and re-renders it in the same style.
    def set_form_context
      @source = params[:source].to_s.presence || "direct"
      @compact = ActiveModel::Type::Boolean.new.cast(params[:compact]).present?
    end

    def confirm_subscription
      @notice = subscription_notice
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_back fallback_location: root_path, notice: @notice, status: :see_other }
      end
    end

    def reject_subscription
      @alert = "Enter a valid email address."
      respond_to do |format|
        format.turbo_stream { render :create, status: :unprocessable_entity }
        format.html { redirect_back fallback_location: root_path, alert: @alert, status: :see_other }
      end
    end

    def subscriber_params
      params.require(:subscriber).permit(:email_address)
    end

    def subscription_notice
      "You're subscribed. The next new dispatch will arrive by email."
    end
end
