require "test_helper"

# The base class for the one test in this suite that drives a real browser.
#
# Everything else here is a unit, model, integration or job test: fast, in
# process, and blind to whether the page a user actually gets is assembled
# correctly. This class exists for the end-to-end proof (test/system/
# full_pipeline_test.rb) — a poll arriving, the model re-running, the newsroom
# publishing, and the site showing all three — which is only worth writing if a
# browser renders it.
#
# System tests are NOT part of `bin/rails test` (Rails excludes test/system by
# design, since they need a browser). They run under `bin/rails test:system`,
# which is a step in bin/ci and its own job in .github/workflows/ci.yml.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Headless Chrome, resolved by Selenium Manager (selenium-webdriver 4.x
  # downloads and caches a matching chromedriver on first use).
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # ActiveJob::TestHelper is included into ActionDispatch::IntegrationTest, and
  # SystemTestCase only borrows that class's Behavior module — so
  # perform_enqueued_jobs has to be asked for here. The pipeline this suite
  # proves is three jobs deep, and running them inline is what makes it one
  # test instead of three.
  include ActiveJob::TestHelper
end
