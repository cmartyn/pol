require "application_system_test_case"

# rails_mind 0.4.0 counts a page view for each HTML GET a controller renders
# for a person. Election night refreshes itself in the background: when the
# snapshot's revision changes it fetches its own HTML and swaps the content
# in. That fetch is the same reader on the same page, so it must not count as
# another visit, or every open tab would add one on each update.
class ElectionNightPageViewsTest < ApplicationSystemTestCase
  test "a background refresh of election night is not counted as another visit" do
    store = Struct.new(:latest).new(snapshot(house: 0.64))
    store.define_singleton_method(:read) { |_name| nil }

    stubbing(ElectionNight::Store, :new, store) do
      as_a_browser do
        with_rails_mind_collecting do |events|
          visit election_night_path
          assert_selector "[data-testid='night-house'] .night-probability", text: "64%"

          store.latest = snapshot(house: 0.71)
          page.execute_script("document.dispatchEvent(new Event('visibilitychange'))")
          assert_selector "[data-testid='night-house'] .night-probability", text: "71%"

          assert_equal [ "ElectionNightController#index" ], page_views(events).map { |view| view["name"] }
        end
      end
    end
  end

  private
    # The SDK counts nothing from HeadlessChrome's own user agent, which names
    # it a headless browser, so the tab presents an ordinary one for the test.
    def as_a_browser
      visit "about:blank"
      browser = page.driver.browser
      original = browser.execute_cdp("Browser.getVersion").fetch("userAgent")
      browser.execute_cdp("Emulation.setUserAgentOverride", userAgent: BROWSER_HEADERS.fetch("User-Agent"))
      yield
    ensure
      browser&.execute_cdp("Emulation.setUserAgentOverride", userAgent: original) if original
    end

    def snapshot(house:)
      {
        "generated_at" => Time.current.iso8601, "prior_as_of" => "2026-11-03", "status" => "experimental",
        "chambers" => {
          "house" => { "p_dem_control" => house, "p_rep_control" => 1 - house, "mean_dem_seats" => 222.3 },
          "senate" => { "p_dem_control" => 0.50, "p_rep_control" => 0.30, "mean_dem_seats" => 50.6 }
        },
        "races" => [ { "race_key" => "NC-01", "p_dem_win" => 0.6, "p_rep_win" => 0.4, "status" => "returns", "observed_votes" => 12345 } ],
        "coverage" => { "races_with_returns" => 1, "races_total" => 470, "races_with_baselines" => 25 },
        "sources" => [],
        "assumptions" => [ "Independent historical turnout assumption" ]
      }
    end
end
