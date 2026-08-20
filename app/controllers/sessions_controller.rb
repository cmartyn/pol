class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      start_new_session_for user

      # PostHog: Identify the user and capture login event
      PostHog.identify(
        distinct_id: user.posthog_distinct_id,
        properties: user.posthog_properties
      )
      PostHog.capture(
        distinct_id: user.posthog_distinct_id,
        event: "user_logged_in"
      )

      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    if Current.user
      # PostHog: Track logout before session ends
      PostHog.capture(
        distinct_id: Current.user.posthog_distinct_id,
        event: "user_logged_out"
      )
    end

    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
