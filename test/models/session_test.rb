require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "from_signed_cookie resolves the session identified by a validly-signed session_id cookie" do
    session = users(:one).sessions.create!
    cookie_jar = ActionDispatch::TestRequest.create.cookie_jar
    cookie_jar.signed[:session_id] = session.id

    assert_equal session, Session.from_signed_cookie(cookie_jar)
  end

  test "from_signed_cookie is nil with no session_id cookie at all" do
    cookie_jar = ActionDispatch::TestRequest.create.cookie_jar
    assert_nil Session.from_signed_cookie(cookie_jar)
  end

  test "from_signed_cookie is nil when the cookie does not match any session" do
    cookie_jar = ActionDispatch::TestRequest.create.cookie_jar
    cookie_jar.signed[:session_id] = 0

    assert_nil Session.from_signed_cookie(cookie_jar)
  end
end
