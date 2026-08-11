ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/stub_helper"
require_relative "test_helpers/wikipedia_stub_helper"
require_relative "test_helpers/poll_factory"
require_relative "test_helpers/newsroom_stub_helper"
require_relative "test_helpers/query_counting"
require_relative "test_helpers/fragment_caching_helper"

# Nothing in this suite is allowed to reach the network. Wikipedia is always
# WebMock-stubbed (see WikipediaStubHelper); localhost stays open for the
# system-test driver.
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    include WikipediaStubHelper
    include StubHelper
    include PollFactory
    include NewsroomStubHelper
    include QueryCounting
    include FragmentCachingHelper
  end
end
