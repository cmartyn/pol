require "test_helper"

class Site::Charts::PollsScatterTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 8, 1) # same fixed date runner_test.rb's golden uses

  test "returns nil when the race has no polls, so the chart omits itself" do
    payload = Site::Charts::PollsScatter.build(
      race: races(:house_ny_17), polls: races(:house_ny_17).polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    assert_nil payload
  end

  test "plots every poll and computes the current weighted average as the reference line" do
    race = races(:senate_maine)
    polls = race.polls.includes(:poll_results, :pollster)

    payload = Site::Charts::PollsScatter.build(race: race, polls: polls, as_of: AS_OF)

    assert_equal "dem", payload[:side_a_party]
    assert_equal "rep", payload[:side_b_party]
    assert_equal 2, payload[:points].size

    # Same hand-derived average as test/lib/forecast/runner_test.rb's golden
    # at the same as-of date: W = 1.1775884, average +2.0130020.
    assert_in_delta 2.01, payload[:average_margin], 0.01

    one = payload[:points].find { |p| p[:pollster] == "Beacon Polling" }
    assert_equal polls(:maine_poll_one).field_end.iso8601, one[:t]
    assert_in_delta 3.5, one[:margin]
    assert_equal polls(:maine_poll_one).source_url, one[:source_url]
    assert_equal 812, one[:sample_size]

    two = payload[:points].find { |p| p[:pollster] == "Cardinal Research" }
    assert_in_delta 1.0, two[:margin]
  end

  test "a poll missing one side's result is left off the scatter, not crashed on" do
    race = races(:senate_maine)
    dem_only_poll = Poll.create!(
      pollster: pollsters(:delta_metrics), race: race,
      field_end: Date.new(2026, 7, 29), sample_size: 500, population: :lv,
      source_url: "https://example.com/polls/maine-3", dedup_digest: "test-dem-only",
      entry_mode: :manual
    )
    dem_only_poll.poll_results.create!(party: :dem, pct: 48.0)

    payload = Site::Charts::PollsScatter.build(
      race: race, polls: race.polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    assert_equal 2, payload[:points].size # still just the two two-sided polls
    assert_not_includes payload[:points].map { |p| p[:source_url] }, dem_only_poll.source_url
  end
end
