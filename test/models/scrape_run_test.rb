require "test_helper"

class ScrapeRunTest < ActiveSupport::TestCase
  test "status enum round-trips every value" do
    ScrapeRun.statuses.each_key do |value|
      run = ScrapeRun.new(status: value)
      assert_equal value, run.status
    end
  end
end
