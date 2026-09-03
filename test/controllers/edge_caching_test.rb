require "test_helper"

# Cloudflare will not cache a response that carries Set-Cookie, and it
# decides cache eligibility before it ever reads Cache-Control. So the whole
# edge-caching scheme rests on one origin-side property: a cacheable page
# must render no CSRF token, because reading form_authenticity_token writes
# _csrf_token into the session and Rails then emits the cookie.
#
# These run inside with_forgery_protection (test/test_helpers/
# forgery_protection_helper.rb) — without it the suite-wide
# allow_forgery_protection = false makes every page tokenless and every
# assertion below vacuous.
# No production action opted into edge_cache redirects today, so the
# after_action's non-200 guard has nothing real to fire against — and a guard
# no test can reach is a guard that silently rots. This probe gives it one.
# It matters because a redirect *does* run after_action callbacks (unlike a
# rescue_from, which unwinds the chain first), so the day someone adds a
# moved-slug redirect to RacesController, an unguarded policy would hand
# Cloudflare a 301 to hold for three minutes.
class EdgeCachingProbeController < PublicController
  edge_cache

  def show
    redirect_to "/", status: :moved_permanently
  end
end

class EdgeCachingTest < ActionDispatch::IntegrationTest
  test "a cacheable page sends no Set-Cookie" do
    with_forgery_protection do
      get root_path

      assert_response :success
      assert_nil response.headers["Set-Cookie"],
        "the dashboard set a cookie, so Cloudflare will refuse to cache it"
    end
  end

  test "a cacheable page tells Cloudflare how long it may hold the page" do
    get root_path

    assert_equal "public, max-age=180, stale-while-revalidate=600, stale-if-error=3600",
      response.headers["CDN-Cache-Control"]
  end

  test "a cacheable page still makes browsers revalidate" do
    get root_path

    # ActionDispatch normalizes the directive order; this is the wire format.
    assert_equal "max-age=0, public, must-revalidate", response.headers["Cache-Control"]
  end

  # The footer form ships inside cached HTML, so it cannot carry a
  # session-bound token. Nothing here is authenticated, so a forged request
  # has no authority to borrow; the honeypot and rate limit are the real
  # defenses and are unaffected.
  test "the subscribe form posts without a CSRF token" do
    with_forgery_protection do
      assert_difference "Subscriber.count", 1 do
        post subscription_path, params: {
          subscriber: { email_address: "friend@example.com" }, source: "footer"
        }
      end
    end
  end

  test "every public content page is edge cacheable" do
    cacheable_paths.each do |path|
      get path

      assert_response :success
      assert_equal EdgeCacheable::EDGE_POLICY, response.headers["CDN-Cache-Control"],
        "#{path} is not edge cacheable"
    end
  end

  # Cached pages break redirect+flash: the subscriber is bounced back to a
  # page Cloudflare is already holding, so the notice never renders and the
  # form looks like it did nothing. Answering the submission in place sidesteps
  # the cache entirely. Both copies of the form appear on the dashboard and the
  # dispatch pages, so the response has to target the one actually submitted.
  test "subscribing swaps the submitted form for a confirmation in place" do
    post subscription_path,
      params: { subscriber: { email_address: "friend@example.com" }, source: "footer" },
      as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/target="subscription-form-footer"/, response.body)
    assert_match(/subscribed/i, response.body)
  end

  # The zone-wide Cloudflare rule marks every path eligible for cache and then
  # defers entirely to these headers, so "not opted in" has to mean "actively
  # refused". A 200 that fell through with no Cache-Control at all would land
  # on Cloudflare's default 120-minute TTL for 200s; Rack::ETag stamping
  # `private` on every unclaimed 200 is what makes silence safe.
  test "personalized public pages are never edge cached" do
    subscriber = Subscriber.subscribe!(email_address: "reader@example.com")

    assert_not_edge_cached email_preferences_path
    assert_not_edge_cached unsubscribe_path(token: subscriber.unsubscribe_token)
  end

  # allow_forgery_protection is a config_accessor whose unset subclass reads
  # fall through to ActionController::Base, so setting it on ApplicationController
  # rather than per-controller would silently disarm CSRF for the authenticated
  # admin — where, unlike the public site, a forged request does have session
  # authority to borrow. Verified by mutation: that hoist turns this 422 into a
  # completed 302 retract.
  test "the CSRF exemption does not reach admin" do
    sign_in_as users(:one)

    with_forgery_protection do
      post retract_admin_dispatch_path(dispatches(:maine_poll_reaction))

      assert_response :unprocessable_entity
    end
  end

  test "admin is never edge cached" do
    sign_in_as users(:one)

    assert_not_edge_cached admin_root_path
    assert_not_edge_cached admin_dispatches_path
  end

  test "a redirect from a cacheable controller is not edge cached" do
    with_routing do |routes|
      routes.draw { get "edge_caching_probe" => "edge_caching_probe#show" }

      get "/edge_caching_probe"

      assert_response :moved_permanently
      assert_nil response.headers["CDN-Cache-Control"]
    end
  end

  # A retracted dispatch 404s, and a cached 404 would outlive the retraction
  # by its own TTL. This holds for a different reason than the redirect above:
  # rescue_from unwinds the callback chain, so the after_action never runs and
  # Rails' default header stands. Pinned so that stays true.
  test "a 404 from a cacheable controller is not itself edge cached" do
    get race_path("no-such-race")

    assert_response :not_found
    assert_nil response.headers["CDN-Cache-Control"]
  end

  private
    def assert_not_edge_cached(path)
      get path

      assert_nil response.headers["CDN-Cache-Control"], "#{path} was offered to the edge cache"
      assert_match(/private|no-cache|no-store/, response.headers["Cache-Control"].to_s,
        "#{path} does not refuse the edge cache, so Cloudflare's zone-wide rule would hold it")
    end

    def cacheable_paths
      [
        root_path, senate_path, house_path,
        race_path(races(:senate_maine).slug),
        dispatches_path, dispatch_path(dispatches(:maine_poll_reaction)),
        polls_path,
        pollsters_path, methodology_path, about_path, privacy_path
      ]
    end
end
