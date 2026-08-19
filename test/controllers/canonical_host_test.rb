require "test_helper"

class CanonicalHostTest < ActionDispatch::IntegrationTest
  setup do
    @previous_canonical_host = ENV["CANONICAL_HOST"]
    ENV["CANONICAL_HOST"] = "535.wtf"
  end

  teardown do
    ENV["CANONICAL_HOST"] = @previous_canonical_host
  end

  test "redirects alternate hosts to the canonical HTTPS URL" do
    host! "www.535.wtf"

    get privacy_path, params: { from: "email" }

    assert_response :moved_permanently
    assert_equal "https://535.wtf/privacy?from=email", response.location
  end

  test "serves the canonical host without redirecting" do
    host! "535.wtf"

    get privacy_path

    assert_response :success
  end

  test "does not redirect proxy health checks" do
    host! "www.535.wtf"

    get rails_health_check_path

    assert_response :success
  end
end
