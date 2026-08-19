class ApplicationController < ActionController::Base
  include Authentication
  prepend_before_action :redirect_to_canonical_host
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # A bad race slug (or any other missing record a controller looks up by
  # hand) renders the site's own 404 rather than Rails' generic error page —
  # "404s for unknown slugs render cleanly" per the Phase 4 brief.
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  private
    def redirect_to_canonical_host
      canonical_host = ENV["CANONICAL_HOST"]
      return if canonical_host.blank? || request.host == canonical_host || request.path == "/up"

      destination = URI::HTTPS.build(
        host: canonical_host,
        path: request.path,
        query: request.query_string.presence
      ).to_s
      redirect_to destination, status: :moved_permanently, allow_other_host: true
    end

    def render_not_found
      render "errors/not_found", status: :not_found
    end
end
