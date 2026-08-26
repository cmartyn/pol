# Opting a public controller into Cloudflare's edge cache.
#
# Cloudflare decides cache eligibility from the request before it reads any
# response header, and HTML is not in its default-cached extension list — so
# a single zone-wide Cache Rule marks everything eligible and defers to the
# origin's headers. That makes this concern the only thing that decides what
# gets cached, which is why it is opt-in rather than a PublicController
# default: a new personalized page (email preferences, unsubscribe) must be
# uncacheable by simply not saying otherwise.
#
# Rails already sends `max-age=0, private, must-revalidate` on every 200 that
# does not set its own header (Rack::ETag stamps it), and Cloudflare will not
# cache `private`. Silence is therefore safe; only this concern speaks up.
module EdgeCacheable
  extend ActiveSupport::Concern

  # How long Cloudflare may serve a page before asking the origin again. The
  # model runs every two hours, so this is not about freshness — it is about
  # how much of an unexpected traffic spike a single droplet has to absorb.
  EDGE_TTL = 180

  # After EDGE_TTL, keep serving the expired page for this long while the
  # refresh happens in the background, so no reader ever waits on the origin.
  STALE_WHILE_REVALIDATE = 600

  # If the origin is failing outright, keep serving the last good forecast for
  # this long rather than showing an error. On one droplet this is the
  # difference between a stale number and no site at all — but a forecast that
  # looks live and is not is its own kind of wrong, so this deliberately fails
  # loud after an hour instead of quietly holding a frozen page all day.
  STALE_IF_ERROR = 3_600

  # Deliberately `max-age`, never `s-maxage`. Per RFC 9111 s4.2.4, which
  # Cloudflare implements, `s-maxage` (like `must-revalidate` and
  # `proxy-revalidate`) forbids serving stale content — so the intuitive
  # `s-maxage=180, stale-while-revalidate=600` silently disables both stale
  # directives above. Splitting browser and edge policy across two headers is
  # what lets the edge hold a copy while browsers still revalidate every hit.
  EDGE_POLICY = "public, max-age=#{EDGE_TTL}, " \
                "stale-while-revalidate=#{STALE_WHILE_REVALIDATE}, " \
                "stale-if-error=#{STALE_IF_ERROR}".freeze


  class_methods do
    # Turning off forgery protection is what makes the page cacheable at all.
    # `csrf_meta_tags` and `form_with`'s token tag are both no-ops when
    # protect_against_forgery? is false, and it is reading
    # form_authenticity_token that writes _csrf_token into the session and
    # makes Rails emit Set-Cookie — which Cloudflare refuses to cache.
    #
    # Nothing here is authenticated, so there is no session authority for a
    # forged request to borrow; the subscribe endpoint's real defenses are its
    # honeypot and rate limit, neither of which this touches.
    def edge_cache
      without_csrf_token
      after_action :apply_edge_cache_policy
    end

    # For the POST target of a form that ships inside cached HTML. It renders
    # nothing cacheable itself, but it has to accept a submission whose form
    # could not embed a token, because the page it came from is shared.
    def without_csrf_token
      self.allow_forgery_protection = false
    end
  end

  private
    # Only ever GET/HEAD 200s. Redirects (subscribe's redirect_back), 404s and
    # anything else keep Rails' `private` default, which Cloudflare will not
    # cache — the fail-safe direction.
    def apply_edge_cache_policy
      return unless request.get? || request.head?
      return unless response.status == 200

      # Browsers revalidate on every navigation and get a cheap 304 off the
      # edge, so a reader who refreshes never sees a number the edge has
      # already replaced. Set through expires_in rather than by hand because
      # ActionDispatch normalizes Cache-Control's directive order anyway.
      #
      # Cloudflare reads CDN-Cache-Control in preference to this. If it ever
      # stopped doing so it would fall back to `max-age=0, must-revalidate`
      # and simply decline to hold the page — no offload, but no stale or
      # leaked response either, which is the right way for this to fail.
      expires_in 0, public: true, must_revalidate: true
      response.headers["CDN-Cache-Control"] = EDGE_POLICY
    end
end
