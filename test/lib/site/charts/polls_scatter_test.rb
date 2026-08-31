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

  # F1 (integration-lite): the old `side_b = rep ? "rep" : "rep"` bug meant a
  # race with no Republican candidate still asked every poll for a "rep"
  # result, found none, and dropped every point — so a genuinely polled race
  # rendered "No public polling" on the race page (app/views/races/
  # show.html.erb renders the poll table only `if polls_scatter`). This race
  # has a Democrat and an independent, no Republican, and a poll that
  # measures exactly that matchup: the scatter must still build.
  test "no Republican on the ballot: the scatter still builds against whichever two sides are actually polled" do
    race = Race.create!(office: :senate, state: "OH", cycle: 2026, slug: "senate-oh-2026-no-rep-scatter-test", lean: 0.0)
    dem = race.candidates.create!(name: "Ada Dean", party: :dem)
    ind = race.candidates.create!(name: "Ty Loner", party: :ind)
    poll = Poll.create!(
      pollster: pollsters(:beacon_polling), race: race,
      field_end: Date.new(2026, 7, 29), sample_size: 600, population: :lv,
      source_url: "https://example.com/polls/oh-no-rep", dedup_digest: "test-no-rep-race",
      entry_mode: :manual
    )
    poll.poll_results.create!(party: :dem, pct: 42.0, candidate: dem)
    poll.poll_results.create!(party: :ind, pct: 39.0, candidate: ind)

    payload = Site::Charts::PollsScatter.build(
      race: race, polls: race.polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    assert_not_nil payload, "a polled race with no Republican must not be treated as unpolled"
    assert_equal "dem", payload[:side_a_party]
    assert_equal "ind", payload[:side_b_party]
    assert_equal 1, payload[:points].size
    assert_in_delta 3.0, payload[:points].first[:margin]
  end

  # The payload carries the words (the JS only places them), so every string
  # the chart shows is pinned here rather than asserted through rendered SVG.
  test "prebuilds every label: side letters, margins, field periods, samples, and the average annotation" do
    race = races(:senate_maine)

    payload = Site::Charts::PollsScatter.build(
      race: race, polls: race.polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    assert_equal "D", payload[:side_a_letter]
    assert_equal "R", payload[:side_b_letter]
    # The same 2.0130020 average the golden pins, worn as an annotation.
    assert_equal "avg D+2.0", payload[:average_label]
    assert_equal "dem", payload[:average_party]

    one = payload[:points].find { |p| p[:pollster] == "Beacon Polling" }
    assert_equal "D+3.5", one[:margin_label]
    assert_equal "dem", one[:party]
    assert_equal "Jul 10–14, 2026", one[:date_label], "a within-month field period says the month once"
    assert_equal "812 LV", one[:sample_label]
    assert_nil one[:sponsor]

    two = payload[:points].find { |p| p[:pollster] == "Cardinal Research" }
    assert_equal "D+1.0", two[:margin_label]
    assert_equal "650 RV", two[:sample_label]
  end

  test "a rep-leading margin letters R, and a tie dresses neutral rather than crediting a side" do
    race = races(:senate_maine)
    rep_poll = create_poll(pollster: pollsters(:delta_metrics), race: race, field_end: Date.new(2026, 7, 26),
                           sample_size: 700, population: :lv, sponsor: "Pine Tree PAC",
                           results: { dem: 44.0, rep: 46.0 })
    tied_poll = create_poll(pollster: create_pollster("Equinox Insights"), race: race,
                            field_end: Date.new(2026, 7, 27), results: { dem: 45.0, rep: 45.0 })

    payload = Site::Charts::PollsScatter.build(
      race: race, polls: race.polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    rep_point = payload[:points].find { |p| p[:source_url] == rep_poll.source_url }
    assert_equal "R+2.0", rep_point[:margin_label]
    assert_equal "rep", rep_point[:party]
    assert_equal "Pine Tree PAC", rep_point[:sponsor]

    tied_point = payload[:points].find { |p| p[:source_url] == tied_poll.source_url }
    assert_equal "Even", tied_point[:margin_label]
    assert_equal "other", tied_point[:party]
  end

  test "date_label collapses across month and year boundaries and copes with missing starts" do
    race = races(:senate_maine)
    cross_month = create_poll(pollster: pollsters(:delta_metrics), race: race,
                              field_start: Date.new(2026, 7, 29), field_end: Date.new(2026, 8, 1),
                              results: { dem: 47.0, rep: 44.0 })
    cross_year = create_poll(pollster: create_pollster("Yearline Surveys"), race: race,
                             field_start: Date.new(2025, 12, 28), field_end: Date.new(2026, 1, 2),
                             results: { dem: 47.0, rep: 44.0 })
    no_start = create_poll(pollster: create_pollster("Endpoint Research"), race: race,
                           field_end: Date.new(2026, 8, 9), results: { dem: 47.0, rep: 44.0 })
    single_day = create_poll(pollster: create_pollster("Overnight Track"), race: race,
                             field_start: Date.new(2026, 7, 21), field_end: Date.new(2026, 7, 21),
                             results: { dem: 47.0, rep: 44.0 })

    payload = Site::Charts::PollsScatter.build(
      race: race, polls: race.polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    labels = payload[:points].to_h { |p| [ p[:source_url], p[:date_label] ] }
    assert_equal "Jul 29–Aug 1, 2026", labels[cross_month.source_url]
    assert_equal "Dec 28, 2025–Jan 2, 2026", labels[cross_year.source_url]
    assert_equal "Aug 9, 2026", labels[no_start.source_url]
    assert_equal "Jul 21, 2026", labels[single_day.source_url],
                 "a single field day reads as one date, same as the poll table"
  end

  test "sample_label pairs the delimited count with its population and degrades honestly" do
    race = races(:senate_maine)
    unknown_population = create_poll(pollster: pollsters(:delta_metrics), race: race,
                                     field_end: Date.new(2026, 7, 26), sample_size: 967,
                                     results: { dem: 47.0, rep: 44.0 })
    unsized = create_poll(pollster: create_pollster("Sample Study A"), race: race,
                          field_end: Date.new(2026, 7, 26), results: { dem: 47.0, rep: 44.0 })
    delimited = create_poll(pollster: create_pollster("Sample Study B"), race: race,
                            field_end: Date.new(2026, 7, 26), sample_size: 1005, population: :rv,
                            results: { dem: 47.0, rep: 44.0 })

    payload = Site::Charts::PollsScatter.build(
      race: race, polls: race.polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    labels = payload[:points].to_h { |p| [ p[:source_url], p[:sample_label] ] }
    assert_equal "1,005 RV", labels[delimited.source_url]
    assert_equal "967", labels[unknown_population.source_url],
                 "an unrecorded population is not a word to print"
    assert_nil labels[unsized.source_url]
  end

  # The three live no-Dem Senate races (Site::RaceSides' header) plot an
  # independent as side A — the axis letters and dot parties have to follow
  # the sides, not assume D/R.
  test "an independent-side race letters its axis I and R and dresses dots by who actually leads" do
    race = Race.create!(office: :senate, state: "NE", cycle: 2026, slug: "senate-ne-2026-ind-scatter-test", lean: 0.0)
    race.candidates.create!(name: "Sam Osteen", party: :ind)
    race.candidates.create!(name: "Pete Rickard", party: :rep)
    create_poll(pollster: pollsters(:beacon_polling), race: race, field_end: AS_OF - 10,
                sample_size: 600, population: :lv, results: { ind: 47.0, rep: 44.0 })
    create_poll(pollster: pollsters(:cardinal_research), race: race, field_end: AS_OF - 5,
                sample_size: 600, population: :lv, results: { ind: 43.0, rep: 46.0 })

    payload = Site::Charts::PollsScatter.build(
      race: race, polls: race.polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    assert_equal "ind", payload[:side_a_party]
    assert_equal "I", payload[:side_a_letter]
    assert_equal "R", payload[:side_b_letter]

    ind_led = payload[:points].find { |p| p[:margin].positive? }
    assert_equal "I+3.0", ind_led[:margin_label]
    assert_equal "ind", ind_led[:party]

    rep_led = payload[:points].find { |p| p[:margin].negative? }
    assert_equal "R+3.0", rep_led[:margin_label]
    assert_equal "rep", rep_led[:party]
  end

  # Mirrors races_controller_test's ambiguous_district_polls: two qualifying
  # polls that measured different matchups get points but no line — and no
  # annotation or line color either, or the JS would draw a label for a line
  # that isn't there.
  test "an ambiguous matchup keeps the average annotation off along with the line" do
    race = races(:house_ny_17)
    create_poll(pollster: pollsters(:beacon_polling), race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:conley|rep:lawler", results: { dem: 51.0, rep: 45.0 })
    create_poll(pollster: pollsters(:cardinal_research), race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:jones|rep:lawler", results: { dem: 44.0, rep: 45.0 })

    payload = Site::Charts::PollsScatter.build(
      race: race, polls: race.polls.includes(:poll_results, :pollster), as_of: AS_OF
    )

    assert_equal :ambiguous_matchup, payload[:average_reason]
    assert_nil payload[:average_margin]
    assert_nil payload[:average_label]
    assert_nil payload[:average_party]
    assert_equal 2, payload[:points].size, "the polls still plot; only the line and its label stay off"
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

  test "the payload carries the internals view's average and flags each internal point" do
    race = races(:senate_maine)
    plain = create_poll(pollster: pollsters(:beacon_polling), field_end: Date.current - 2,
                        race: race, sample_size: 600, results: { dem: 50.0, rep: 44.0 })
    internal = create_poll(pollster: pollsters(:cardinal_research), field_end: Date.current - 1,
                           race: race, sample_size: 600, partisan: :dem,
                           results: { dem: 56.0, rep: 40.0 })

    payload = Site::Charts::PollsScatter.build(race: race, polls: [ plain, internal ],
                                               internals_shift: 3.0)

    # Published view: the internal poll is a dot, not part of the average.
    assert_in_delta 6.0, payload[:average_margin], 0.01
    # Internals view: margin 16 shifted to 13 at half weight against margin 6
    # at (near) full weight moves the average up, but nowhere near 13.
    assert_operator payload.dig(:incl, :average_margin), :>, payload[:average_margin]
    assert_operator payload.dig(:incl, :average_margin), :<, 13.0
    flags = payload[:points].to_h { |point| [ point[:pollster], point[:internal] ] }
    assert_equal({ pollsters(:beacon_polling).name => false, pollsters(:cardinal_research).name => true }, flags)
  end
end
