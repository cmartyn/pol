# The suite runs with RailsMind collection off: config/initializers/rails_mind.rb
# clears the key in test, so no page view is counted and no visitor cookie is
# set. A test that needs to see what the SDK would send, or what it would do to
# a response, swaps in a client built from the app's own configuration with an
# in-memory collector. Nothing leaves the process.
module RailsMindCollectorHelper
  class MemoryCollector
    attr_reader :events

    def initialize = @events = []
    def push(event) = (@events << event; true)
  end

  # The SDK counts no page view for a blank or known-bot user agent, and
  # integration tests send none, so a test that wants one counted says it is
  # a browser.
  BROWSER_HEADERS = {
    "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
                    "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
  }.freeze

  def with_rails_mind_collecting
    previous = RailsMind.client
    collector = MemoryCollector.new
    RailsMind.client = RailsMind::Client.new(RailsMind.configuration, collector: collector)
    yield collector.events
  ensure
    RailsMind.client = previous
    RailsMind::Context.current.clear
  end

  def page_views(events) = events.select { |event| event["kind"] == "pageview" }
end
