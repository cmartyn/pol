require "application_system_test_case"

# The subscribe form's response path is the one part of edge caching that a
# request spec cannot prove. Every page the form ships on is now held by
# Cloudflare, so the old redirect_back would bounce the reader onto a cached
# copy where the flash does not exist and the form looks inert. The
# turbo_stream reply sidesteps the cache by never navigating at all — but only
# if Turbo actually intercepts the submit and matches the target id, which
# takes a real browser to know.
class SubscriptionFormTest < ApplicationSystemTestCase
  test "subscribing answers in place without navigating away" do
    visit root_path

    within "#subscription-form-footer" do
      fill_in "Email address", with: "reader@example.com"
      click_on "Subscribe"
    end

    within "#subscription-form-footer" do
      assert_text(/subscribed/i)
      assert_no_selector "input[type=email]"
    end

    # A redirect would have reloaded the page and rebuilt both copies as forms.
    # The dashboard's own copy still being a form is what proves the response
    # replaced only the one submitted, in place.
    assert_selector "#subscription-form-homepage input[type=email]"
    assert_equal "reader@example.com", Subscriber.last.email_address
  end
end
