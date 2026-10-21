require "application_system_test_case"

class PollMatchupFilterTest < ApplicationSystemTestCase
  setup do
    @race = races(:senate_maine)
    @race.polls.destroy_all
  end

  test "keyboard selection and reset keep polling groups truthful on desktop and mobile" do
    current = add_poll("dem:ellis|rep:rivers", 0,
      columns: { "Jordan Ellis (D)" => "51%", "Pat Rivers (R)" => "45%" })
    add_poll(current.matchup_key, 1)
    historical = add_poll("dem:jones|rep:rivers", 30,
      columns: { "Pat Jones (D)" => "51%", "Pat Rivers (R)" => "45%" })
    unknown = add_poll(nil, 40)
    empty = add_poll("", 50)

    [ [ 1400, 1000 ], [ 375, 812 ] ].each do |width, height|
      with_viewport(width, height) do
        visit race_path(@race.slug)
        assert_equal width, page.evaluate_script("window.innerWidth")
        assert_selector "[data-testid='poll-row']", count: 5
        assert_selector "[data-testid='poll-matchup-heading']", count: 4
        matchup_select = find_field("Candidate matchup")
        assert_equal "", matchup_select.value
        assert_equal "poll-matchup-help", matchup_select["aria-describedby"]
        assert_text "Filters this polling table only. Forecast values and scatter-chart data remain unchanged."
        forecast = find("[data-testid='win-probability']").text
        chart_data = find("[data-polls-scatter-chart-target='payload']", visible: :all).text(:all)

        # Tab reaches the native select; arrows commit a selection without a mouse.
        matchup_select.send_keys(:tab)
        page.driver.browser.action.key_down(:shift).send_keys(:tab).key_up(:shift).perform
        assert_equal "poll-matchup", page.evaluate_script("document.activeElement.id")
        matchup_select.send_keys(:home, :arrow_down, :enter)
        assert_only_group(current, 2)
        assert_unchanged_forecast_and_chart(forecast, chart_data)
        assert_no_selector "[data-testid='earlier-matchup-tag']"
        assert_selector "[role='status']", text: "Showing 2 polls for this matchup."

        matchup_select.send_keys(:arrow_down, :enter)
        assert_only_group(historical, 1)
        assert_unchanged_forecast_and_chart(forecast, chart_data)
        assert_selector "[data-testid='earlier-matchup-tag']", text: "Polled before the field was set"

        # Missing and empty keys are real groups, never the reset sentinel.
        [ unknown, empty ].each do |poll|
          matchup_select.send_keys(:arrow_down, :enter)
          assert_only_group(poll, 1)
          assert_unchanged_forecast_and_chart(forecast, chart_data)
          assert_selector "[data-testid='poll-matchup-heading']", text: /Matchup not recorded/i
          assert_no_selector "[data-testid='earlier-matchup-tag']"
        end

        matchup_select.send_keys(:home, :enter)
        assert_selector "[data-testid='poll-row']", count: 5
        assert_selector "[data-testid='poll-matchup-heading']", count: 4
        assert_selector "[data-testid='poll-source-link']", count: 5
        assert_selector "[role='status']", text: "Showing 5 polls across all matchups."
        assert_unchanged_forecast_and_chart(forecast, chart_data)
        assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "page fits viewport"
      end
    end
  end

  test "three groups keep accurate counts for small and large polling tables" do
    [ [ 1, 1, 1 ], [ 100, 60, 40 ] ].each do |counts|
      @race.polls.reload.destroy_all
      days_ago = 0
      [ "dem:ellis|rep:rivers", "dem:jones|rep:rivers", nil ].zip(counts).each do |key, count|
        count.times do
          add_poll(key, days_ago)
          days_ago += 1
        end
      end
      @race.touch

      with_viewport(375, 812) do
        visit race_path(@race.slug)
        assert_equal 375, page.evaluate_script("window.innerWidth")
        assert_selector "[data-testid='poll-row']", count: counts.sum
        assert_selector "[data-testid='poll-matchup-heading']", count: 3
        assert_selector "[role='status']", text: "Showing #{counts.sum} polls across all matchups."
        forecast = find("[data-testid='win-probability']").text
        chart_data = find("[data-polls-scatter-chart-target='payload']", visible: :all).text(:all)

        find_field("Candidate matchup").select("Matchup not recorded · #{counts.last} #{counts.last == 1 ? 'poll' : 'polls'}")
        assert_selector "[data-testid='poll-matchup-heading']", count: 1, text: /Matchup not recorded/i
        assert_selector "[data-testid='poll-row']", count: counts.last
        assert_selector "[data-testid='poll-source-link']", count: counts.last
        assert_selector "[role='status']", text: "Showing #{counts.last} #{counts.last == 1 ? 'poll' : 'polls'} for this matchup."
        assert_unchanged_forecast_and_chart(forecast, chart_data)

        find_field("Candidate matchup").select("All matchups")
        assert_selector "[data-testid='poll-row']", count: counts.sum
        assert_selector "[data-testid='poll-matchup-heading']", count: 3
        assert_selector "[data-testid='poll-source-link']", count: counts.sum
        assert_unchanged_forecast_and_chart(forecast, chart_data)
        assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "page fits viewport"
      end
    end
  end

  test "single matchup and no polling need no filter" do
    poll = add_poll("dem:ellis|rep:rivers", 0)
    visit race_path(@race.slug)
    assert_no_selector "select#poll-matchup"
    assert_no_selector "[data-testid='poll-matchup-heading']"
    assert_selector "[data-testid='poll-row']", count: 1
    assert_selector "a[data-testid='poll-source-link'][href='#{poll.source_url}']"

    @race.polls.reload.destroy_all
    @race.touch
    visit race_path(@race.slug)
    assert_selector "[data-testid='unpolled-empty-state']", text: "No public polling"
    assert_no_selector "select#poll-matchup"
    assert_no_selector "[data-testid='poll-table']"
  end

  private
    # Chrome's minimum window width can exceed a phone's width. Device metrics
    # give this test a genuine CSS viewport, verified with window.innerWidth.
    def with_viewport(width, height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: width < 640)
      yield
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end

    def assert_unchanged_forecast_and_chart(forecast, chart_data)
      assert_equal forecast, find("[data-testid='win-probability']").text
      assert_equal chart_data, find("[data-polls-scatter-chart-target='payload']", visible: :all).text(:all)
    end

    def add_poll(key, days_ago, columns: nil)
      create_poll(pollster: pollsters(:beacon_polling), race: @race,
        field_end: Date.current - days_ago, sample_size: 600,
        results: { dem: 51.0, rep: 45.0 }, matchup_key: key,
        raw_payload: columns ? { "columns" => columns } : {})
    end

    def assert_only_group(poll, count)
      assert_selector "[data-testid='poll-matchup-heading']", count: 1
      assert_selector "[data-testid='poll-matchup-heading']", text: /#{Regexp.escape(poll.matchup_heading)}/i
      assert_selector "[data-testid='poll-matchup-heading']", text: "#{count} #{count == 1 ? 'poll' : 'polls'}"
      assert_selector "[data-testid='poll-row']", count: count
      assert_selector "[data-testid='poll-source-link']", count: count
      assert_selector "a[data-testid='poll-source-link'][href='#{poll.source_url}']"
    end
end
