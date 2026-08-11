require "test_helper"

# Every expected number below is worked out by hand from the published formula
#
#   weight = exp(-ln2 × age_days / 14) × sqrt(min(n, 1500) / 600)
#
# and written into the test as a literal, so a change to the implementation
# cannot quietly move the goalposts. The derivations are in the comments.
class Forecast::AveragerTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 8, 1)

  setup do
    @averager = Forecast::Averager.new(as_of: AS_OF)
    @beacon = pollsters(:beacon_polling)
    @cardinal = pollsters(:cardinal_research)
    @delta = pollsters(:delta_metrics)
  end

  # w(age 0, n 600)  = 1 × sqrt(600/600)  = 1.0
  # w(age 14, n 2400) = 0.5 × sqrt(1500/600) = 0.5 × 1.5811388 = 0.7905694
  # mean = (6.0 × 1.0 + −3.0 × 0.7905694) / 1.7905694 = 2.0263340
  test "two polls average to their weighted mean" do
    polls = [
      create_poll(pollster: @beacon, field_end: AS_OF, sample_size: 600, results: { dem: 50.0, rep: 44.0 }),
      create_poll(pollster: @cardinal, field_end: AS_OF - 14, sample_size: 2400, results: { dem: 45.0, rep: 48.0 })
    ]

    result = @averager.call(polls: polls)

    assert_in_delta 2.0263, result.mean_margin, 0.00005
    assert_in_delta 1.7905694, result.weight, 1e-7
    assert_equal 2, result.poll_count
    assert_equal 45, result.window_days
    assert_equal 0, result.skipped_count
  end

  # The sample-size cap bites at 1500: a 2400-person poll and a 1500-person
  # poll of the same age weigh exactly the same.
  test "sample size is capped before the square root" do
    huge = create_poll(pollster: @beacon, field_end: AS_OF, sample_size: 24_000, results: { dem: 50.0, rep: 44.0 })
    capped = create_poll(pollster: @cardinal, field_end: AS_OF, sample_size: 1500, results: { dem: 50.0, rep: 44.0 })

    assert_in_delta @averager.weight_for(capped), @averager.weight_for(huge), 1e-12
    assert_in_delta 1.5811388, @averager.weight_for(huge), 1e-7
  end

  # w(age 7, n 400) = 2^(-0.5) × sqrt(400/600) = 0.7071068 × 0.8164966 = 0.5773503
  test "a poll with no sample size falls back to the default of 400" do
    poll = create_poll(pollster: @beacon, field_end: AS_OF - 7, sample_size: nil, results: { dem: 51.0, rep: 46.0 })

    result = @averager.call(polls: [ poll ])

    assert_in_delta 5.0, result.mean_margin, 1e-9
    assert_in_delta 0.5773503, result.weight, 1e-7
  end

  # w(0, 1500) = 1.5811388, w(21, 600) = 2^(-1.5) = 0.3535534, w(42, 400) = 2^(-3) × 0.8164966 = 0.1020621
  # mean = (3.0 × 1.5811388 + −1.0 × 0.3535534 + 8.0 × 0.1020621) / 2.0367543 = 2.5562041
  test "three polls of different ages and sizes average to their weighted mean" do
    polls = [
      create_poll(pollster: @beacon, field_end: AS_OF, sample_size: 1500, results: { dem: 48.0, rep: 45.0 }),
      create_poll(pollster: @cardinal, field_end: AS_OF - 21, sample_size: 600, results: { dem: 44.0, rep: 45.0 }),
      create_poll(pollster: @delta, field_end: AS_OF - 42, sample_size: 400, results: { dem: 52.0, rep: 44.0 })
    ]

    result = @averager.call(polls: polls)

    assert_in_delta 2.5562, result.mean_margin, 0.00005
    assert_in_delta 2.0367543, result.weight, 1e-7
    assert_equal 3, result.poll_count
  end

  # Only one poll inside 45 days, so the window widens to 120 and the June poll
  # joins in. w(10, 600) = 0.6095068, w(60, 900) = 0.0627938.
  # mean = (4.0 × 0.6095068 + −2.0 × 0.0627938) / 0.6723007 = 3.4395914
  test "the window widens to 120 days when fewer than two polls qualify" do
    polls = [
      create_poll(pollster: @beacon, field_end: AS_OF - 10, sample_size: 600, results: { dem: 49.0, rep: 45.0 }),
      create_poll(pollster: @cardinal, field_end: AS_OF - 60, sample_size: 900, results: { dem: 45.0, rep: 47.0 })
    ]

    result = @averager.call(polls: polls)

    assert_equal 120, result.window_days
    assert_equal 2, result.poll_count
    assert_in_delta 3.4396, result.mean_margin, 0.00005
  end

  test "the window stays at 45 days when two polls already qualify" do
    polls = [
      create_poll(pollster: @beacon, field_end: AS_OF - 10, sample_size: 600, results: { dem: 49.0, rep: 45.0 }),
      create_poll(pollster: @cardinal, field_end: AS_OF - 44, sample_size: 600, results: { dem: 45.0, rep: 47.0 }),
      create_poll(pollster: @delta, field_end: AS_OF - 60, sample_size: 900, results: { dem: 40.0, rep: 50.0 })
    ]

    result = @averager.call(polls: polls)

    assert_equal 45, result.window_days
    assert_equal 2, result.poll_count
  end

  test "a poll exactly on the window boundary is inside it" do
    polls = [
      create_poll(pollster: @beacon, field_end: AS_OF - 45, sample_size: 600, results: { dem: 50.0, rep: 44.0 }),
      create_poll(pollster: @cardinal, field_end: AS_OF - 45, sample_size: 600, results: { dem: 50.0, rep: 44.0 })
    ]

    result = @averager.call(polls: polls)

    assert_equal 45, result.window_days
    assert_equal 2, result.poll_count
  end

  test "nothing in either window leaves the average empty rather than zero" do
    poll = create_poll(pollster: @beacon, field_end: AS_OF - 200, sample_size: 600, results: { dem: 50.0, rep: 44.0 })

    result = @averager.call(polls: [ poll ])

    assert_nil result.mean_margin
    assert_equal 0.0, result.weight
    assert_equal 0, result.poll_count
    refute_predicate result, :polled?
  end

  test "a poll fielded after the as-of date is not in hand yet" do
    poll = create_poll(pollster: @beacon, field_end: AS_OF + 1, sample_size: 600, results: { dem: 50.0, rep: 44.0 })

    result = @averager.call(polls: [ poll ])

    assert_equal 0, result.poll_count
    assert_nil result.mean_margin
  end

  test "one poll per pollster: the latest field_end wins" do
    stale = create_poll(pollster: @beacon, field_end: AS_OF - 20, sample_size: 600, results: { dem: 60.0, rep: 40.0 })
    fresh = create_poll(pollster: @beacon, field_end: AS_OF - 2, sample_size: 600, results: { dem: 48.0, rep: 46.0 })
    other = create_poll(pollster: @cardinal, field_end: AS_OF - 2, sample_size: 600, results: { dem: 48.0, rep: 46.0 })

    result = @averager.call(polls: [ stale, fresh, other ])

    assert_equal 2, result.poll_count
    assert_in_delta 2.0, result.mean_margin, 1e-9
  end

  test "one poll per pollster: same field_end breaks the tie on field_start, then id" do
    short = create_poll(pollster: @beacon, field_end: AS_OF - 5, field_start: AS_OF - 6,
                        sample_size: 600, results: { dem: 40.0, rep: 50.0 })
    long = create_poll(pollster: @beacon, field_end: AS_OF - 5, field_start: AS_OF - 12,
                       sample_size: 600, results: { dem: 55.0, rep: 45.0 })

    # The later field_start wins, whichever order the polls arrive in.
    assert_in_delta(-10.0, @averager.call(polls: [ short, long ]).mean_margin, 1e-9)
    assert_in_delta(-10.0, @averager.call(polls: [ long, short ]).mean_margin, 1e-9)

    # With field_start equal too, the higher id wins.
    twin = create_poll(pollster: @beacon, field_end: AS_OF - 5, field_start: AS_OF - 6,
                       sample_size: 600, results: { dem: 52.0, rep: 44.0 })
    assert_in_delta 8.0, @averager.call(polls: [ twin, short ]).mean_margin, 1e-9
  end

  test "a poll with no field_start is treated as a single-day poll for the tie-break" do
    dated = create_poll(pollster: @beacon, field_end: AS_OF - 5, field_start: AS_OF - 9,
                        sample_size: 600, results: { dem: 40.0, rep: 50.0 })
    undated = create_poll(pollster: @beacon, field_end: AS_OF - 5, field_start: nil,
                          sample_size: 600, results: { dem: 55.0, rep: 45.0 })

    assert_in_delta 10.0, @averager.call(polls: [ dated, undated ]).mean_margin, 1e-9
  end

  test "the top result in each party is the one that counts" do
    poll = create_poll(pollster: @beacon, field_end: AS_OF, sample_size: 600,
                       results: [ [ :dem, 44.0 ], [ :dem, 47.5 ], [ :rep, 45.0 ], [ :rep, 41.0 ] ])

    assert_in_delta 2.5, @averager.call(polls: [ poll ]).mean_margin, 1e-9
  end

  test "a poll missing one of the two sides is counted out, not counted as zero" do
    matchup = create_poll(pollster: @beacon, field_end: AS_OF, sample_size: 600, results: { dem: 50.0, rep: 44.0 })
    one_sided = create_poll(pollster: @cardinal, field_end: AS_OF, sample_size: 600, results: { dem: 62.0 })

    result = @averager.call(polls: [ matchup, one_sided ])

    assert_equal 1, result.poll_count
    assert_equal 1, result.skipped_count
    assert_in_delta 6.0, result.mean_margin, 1e-9
  end

  # Nebraska in miniature: Osborn (I) against Ricketts (R), with the same
  # pollster also publishing a hypothetical Democrat-vs-Ricketts row. Averaging
  # the independent's matchup has to keep the poll that measures it.
  test "sides other than dem and rep can be averaged" do
    hypothetical = create_poll(pollster: @beacon, field_end: AS_OF, field_start: AS_OF - 3,
                               sample_size: 600, results: { dem: 39.0, rep: 49.0 })
    real = create_poll(pollster: @beacon, field_end: AS_OF, field_start: AS_OF - 3,
                       sample_size: 600, results: { ind: 47.0, rep: 42.0 })

    result = @averager.call(polls: [ hypothetical, real ], side_a: :ind, side_b: :rep)

    assert_equal 1, result.poll_count
    assert_equal 1, result.skipped_count
    assert_in_delta 5.0, result.mean_margin, 1e-9

    # ... and read as a two-party race the same pair gives the hypothetical.
    two_party = @averager.call(polls: [ hypothetical, real ])
    assert_in_delta(-10.0, two_party.mean_margin, 1e-9)
  end

  test "the widening test counts polls that measure the matchup, not raw rows" do
    measured = create_poll(pollster: @beacon, field_end: AS_OF - 5, sample_size: 600, results: { dem: 50.0, rep: 44.0 })
    one_sided = create_poll(pollster: @cardinal, field_end: AS_OF - 6, sample_size: 600, results: { dem: 48.0 })
    older = create_poll(pollster: @delta, field_end: AS_OF - 100, sample_size: 600, results: { dem: 47.0, rep: 46.0 })

    result = @averager.call(polls: [ measured, one_sided, older ])

    assert_equal 120, result.window_days
    assert_equal 2, result.poll_count
    assert_equal 1, result.skipped_count
  end

  test "asking for the same party on both sides is a programming error" do
    assert_raises(ArgumentError) { @averager.call(polls: [], side_a: :dem, side_b: :dem) }
  end

  test "for_race reads the race's own polls out of the database" do
    race = Race.create!(office: :senate, state: "OH", cycle: 2026, slug: "senate-oh-averager-test", lean: -5.0)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600, results: { dem: 47.0, rep: 45.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 3, sample_size: 600, results: { dem: 46.0, rep: 48.0 })
    create_poll(pollster: @delta, field_end: AS_OF - 3, sample_size: 600, results: { dem: 90.0, rep: 1.0 })

    result = @averager.for_race(race)

    assert_equal 2, result.poll_count
    assert_in_delta 0.0, result.mean_margin, 1e-9
  end

  test "for_generic_ballot reads only the race-less polls" do
    create_poll(pollster: @beacon, field_end: AS_OF - 1, sample_size: 600, results: { dem: 49.0, rep: 44.0 })
    create_poll(pollster: @cardinal, race: races(:senate_maine), field_end: AS_OF - 1,
                sample_size: 600, results: { dem: 80.0, rep: 10.0 })

    result = @averager.for_generic_ballot

    # The fixture generic-ballot poll (Delta Metrics, 46.5–44.5, field_end
    # 2026-07-28, n=1200) is in the window too.
    assert_equal 2, result.poll_count
    assert_operator result.mean_margin, :>, 2.0
    assert_operator result.mean_margin, :<, 5.0
  end
end
