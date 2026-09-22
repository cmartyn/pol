class UnsubscribesController < PublicController
  skip_forgery_protection only: :create

  before_action :set_subscriber

  def show
    render :invalid, status: :not_found unless @subscriber
  end

  def create
    if @subscriber
      @subscriber.unsubscribe!
      if @subscriber.saved_change_to_status?
        @subscriber.capture_posthog(
          "subscriber_unsubscribed",
          { via: params[:browser_confirmation].present? ? "browser" : "one_click" }
        )
        # Email-preferences is not edge-cached, so this id is safe to render
        # there. One-click unsubscribes have no browser to identify.
        if params[:browser_confirmation].present? && !Current.user
          flash[:posthog_identify] = @subscriber.posthog_distinct_id
        end
      end
    end

    if params[:browser_confirmation].present?
      redirect_to email_preferences_path, notice: "You're unsubscribed from 535 dispatches.", status: :see_other
    else
      head :ok
    end
  end

  private
    def set_subscriber
      @subscriber = Subscriber.from_unsubscribe_token(params[:token])
    end
end
