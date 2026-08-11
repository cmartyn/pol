require "test_helper"

# Deliverable 1's core promise: every /admin route requires authentication,
# and the GoodJob dashboard mount is gated by the same session. This asks
# the router itself for every admin/* route rather than hand-listing them,
# so a controller action added later is covered automatically instead of
# silently slipping past this test the way a hand-maintained list could.
class Admin::AuthenticationTest < ActionDispatch::IntegrationTest
  test "every admin controller route redirects to sign-in when unauthenticated" do
    admin_routes = Rails.application.routes.routes.select do |route|
      route.defaults[:controller]&.start_with?("admin/")
    end

    # A floor, not an exact count: guards against this test silently
    # covering nothing if routes.rb's namespace shape ever changes, without
    # being so exact it breaks every time a new admin action is added.
    assert_operator admin_routes.size, :>=, 25,
      "expected to find every admin/* route via the router; found only #{admin_routes.size} — did routes.rb change shape?"

    admin_routes.each do |route|
      path = route.path.spec.to_s.sub(/\(\.:format\)\z/, "").gsub(/:\w+/, "1")
      description = "#{route.verb} #{path} (#{route.defaults[:controller]}##{route.defaults[:action]})"

      case route.verb
      when "GET" then get path
      when "POST" then post path
      when "PATCH" then patch path
      when "PUT" then put path
      when "DELETE" then delete path
      else
        next
      end

      assert_response :redirect, "expected #{description} to redirect when unauthenticated, got #{response.status}"
      assert_redirected_to new_session_path, "expected #{description} to redirect to sign-in"
    end
  end

  test "the GoodJob dashboard is not reachable without authentication" do
    get "/admin/good_job"
    assert_response :not_found
  end

  test "the GoodJob dashboard is reachable once authenticated" do
    sign_in_as users(:one)
    get "/admin/good_job"
    # GoodJob's own root redirects internally to its jobs index
    # (good_job/jobs#redirect_to_index) — that's the engine's normal
    # behavior once past the auth gate, not a sign of being blocked.
    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "the GoodJob dashboard rejects a forged/unsigned session cookie the same way as no cookie at all" do
    cookies["session_id"] = "not-a-real-signed-value"
    get "/admin/good_job"
    assert_response :not_found
  end
end
