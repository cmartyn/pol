require "test_helper"

class PollsterExclusionIntegrationTest < ActionDispatch::IntegrationTest
  setup { @pollster = pollsters(:beacon_polling) }

  test "cached public lists drop excluded polls while the public archive explains and preserves them" do
    with_fragment_caching do
      get polls_path
      assert_select "[data-poll-id='#{polls(:maine_poll_one).id}']"
      get race_path(races(:senate_maine).slug)
      assert_select "body", text: /Beacon Polling/
      get pollsters_path
      assert_select "[data-testid='pollster-row']", text: /Beacon Polling/

      @pollster.update!(excluded: true, exclusion_reason: "Polls were withdrawn", exclusion_source_url: "https://example.com/notice")

      get polls_path
      assert_response :success
      assert_select "[data-poll-id='#{polls(:maine_poll_one).id}']", count: 0
      assert_select "[data-poll-id='#{polls(:maine_poll_two).id}']"
      get race_path(races(:senate_maine).slug)
      assert_select "[data-testid='forecast-exclusion-pending']"
      assert_select "[data-testid='poll-table']", text: /Beacon Polling/, count: 0
      get pollsters_path
      assert_select "[data-testid='pollster-row']", text: /Beacon Polling/, count: 0
      assert_select "[data-testid='excluded-pollsters']", text: /Polls were withdrawn/

      @pollster.update!(exclusion_reason: "Confirmed fabrication")
      get pollsters_path
      assert_select "[data-testid='excluded-pollsters']", text: /Confirmed fabrication/
      get pollster_path(@pollster)
      assert_response :success
      assert_select "[data-testid='pollster-exclusion']", text: /Confirmed fabrication/
      assert_select "a[href='https://example.com/notice']"
      assert_select "[data-poll-id='#{polls(:maine_poll_one).id}']", text: /Excluded/

      @pollster.update!(excluded: false)
      get polls_path
      assert_select "[data-poll-id='#{polls(:maine_poll_one).id}']"
      get pollsters_path
      assert_select "[data-testid='excluded-pollsters']", count: 0
      assert_select "[data-testid='pollster-row']", text: /Beacon Polling/
    end
  end

  test "the archive paginates within a pollster and bounds out-of-range pages" do
    get pollster_path(@pollster, page: 999)
    assert_redirected_to pollster_path(@pollster)
    follow_redirect!
    assert_select "[data-testid='poll-feed-row']", count: 1
    assert_select "[data-poll-id='#{polls(:maine_poll_two).id}']", count: 0
  end

  test "published dispatches carry a warning without rewriting or retracting their text" do
    dispatch = dispatches(:maine_poll_reaction)
    original = dispatch.body_markdown
    @pollster.update!(excluded: true, exclusion_reason: "Withdrawn")
    get dispatch_path(dispatch)
    assert_response :success
    assert_select "[data-testid='dispatch-excluded-pollster'] a[href='#{pollster_path(@pollster)}']"
    assert_equal original, dispatch.reload.body_markdown
    assert_predicate dispatch, :published?
  end
end
