# config/environments/test.rb turns request forgery protection off for the
# whole suite (line 37), which is right for every test that just wants to
# POST a form without threading a token through it. But it also hides the
# exact property edge caching depends on: that a cacheable page renders no
# CSRF token, therefore writes nothing to the session, therefore sends no
# Set-Cookie — and Cloudflare will not cache a response carrying one.
# With protection off suite-wide, *every* page is tokenless, so a
# Set-Cookie assertion passes whether or not EdgeCacheable does its job.
#
# Following FragmentCachingHelper's precedent, a test that needs to prove
# that property opts protection back on for its own duration.
# `allow_forgery_protection` is a config_accessor backed by an
# InheritableOptions hash, so a subclass that never sets it falls through
# to ActionController::Base at *read* time. Flipping it here therefore
# reaches every controller except the ones EdgeCacheable has explicitly set
# it false on — which is precisely the distinction under test.
module ForgeryProtectionHelper
  def with_forgery_protection
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
