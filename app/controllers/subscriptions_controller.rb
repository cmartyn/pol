class SubscriptionsController < PublicController
  without_csrf_token

  rate_limit to: 8, within: 3.minutes, only: :create

  # The shapes shared/_subscription_form knows how to draw. Anything else
  # coming back from a form is a typo or a probe, and gets the plain card.
  FORM_LAYOUTS = %w[card wide compact].freeze

  before_action :set_form_context, only: :create

  def create
    if params[:website].present?
      return confirm_subscription
    end

    subscriber = Subscriber.subscribe!(
      email_address: subscriber_params[:email_address],
      source: params[:source]
    )

    track_subscription(subscriber)
    confirm_subscription
  rescue ActiveRecord::RecordInvalid
    # A rejected address is not a person. The count is still useful.
    PostHog.capture(
      event: "subscriber_signup_rejected",
      properties: { "$process_person_profile" => false }
    )
    reject_subscription
  end

  private
    # Which of the page's two form copies was submitted, so the turbo_stream
    # response replaces that one and re-renders it in the same style. A form
    # rendered before `layout` existed sends `compact` instead, and copies
    # held at the edge or left open in a tab keep sending it for a while.
    def set_form_context
      @source = params[:source].to_s.presence || "direct"
      @layout = params[:layout].to_s.presence_in(FORM_LAYOUTS) ||
        (ActiveModel::Type::Boolean.new.cast(params[:compact]) ? "compact" : "card")
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

    def track_subscription(subscriber)
      event = if subscriber.previously_new_record?
        "subscriber_signed_up"
      elsif subscriber.saved_change_to_status?
        "subscriber_resubscribed"
      end
      return unless event

      subscriber.capture_posthog(event, { source: subscriber.source.presence || "direct" })
      # The turbo response identifies the browser. Skip that when an editor is
      # signed in, so their PostHog person is not merged into the subscriber.
      @posthog_distinct_id = subscriber.posthog_distinct_id unless Current.user
    end

    def subscriber_params
      params.require(:subscriber).permit(:email_address)
    end

    def subscription_notice
      "You're subscribed. The next new dispatch will arrive by email."
    end
end
