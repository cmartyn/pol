class UnsubscribesController < PublicController
  skip_forgery_protection only: :create

  before_action :set_subscriber

  def show
    render :invalid, status: :not_found unless @subscriber
  end

  def create
    @subscriber&.unsubscribe!

    # PostHog: Track unsubscribe (key churn event)
    if @subscriber
      PostHog.capture(
        distinct_id: "subscriber:#{@subscriber.id}",
        event: "subscriber_unsubscribed",
        properties: { via: params[:browser_confirmation].present? ? "browser" : "one_click" }
      )
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
