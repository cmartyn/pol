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

  # A sample size of zero reaches the database only through manual or CSV
  # entry — the scraper normalises it to nil — and it means "unknown", not "a
  # poll of nobody". Weighed literally it would be zero, which at one poll
  # would leave the average with a weight of zero and no mean at all.
  test "a sample size of zero is read as unknown, like a missing one" do
    zero = create_poll(pollster: @beacon, field_end: AS_OF - 7, sample_size: 0, results: { dem: 51.0, rep: 46.0 })
    missing = create_poll(pollster: @cardinal, field_end: AS_OF - 7, sample_size: nil, results: { dem: 51.0, rep: 46.0 })

    assert_in_delta @averager.weight_for(missing), @averager.weight_for(zero), 1e-12
    assert_in_delta 0.5773503, @averager.weight_for(zero), 1e-7

    result = @averager.call(polls: [ zero ])
    assert_predicate result, :polled?
    assert_in_delta 5.0, result.mean_margin, 1e-9
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

  # The widening threshold is a parameter like every other constant in this
  # class, not a literal that happens to equal the file. Raising it to three
  # makes the same two polls too thin to stand on their own.
  test "the widening threshold comes from the params file" do
    assert_equal 2, Pol::Params.fetch!(:averaging, :min_polls_in_window)

    polls = [
      create_poll(pollster: @beacon, field_end: AS_OF - 10, sample_size: 600, results: { dem: 49.0, rep: 45.0 }),
      create_poll(pollster: @cardinal, field_end: AS_OF - 12, sample_size: 600, results: { dem: 47.0, rep: 46.0 })
    ]

    assert_equal 45, @averager.call(polls: polls).window_days

    with_params(averaging: { min_polls_in_window: 3 }) do
      assert_equal 120, Forecast::Averager.new(as_of: AS_OF).call(polls: polls).window_days
    end
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

  # ---------------------------------------------------------------------
  # Districts whose polls disagree about who is running
  # ---------------------------------------------------------------------

  def district(slug, district_number)
    Race.create!(office: :house, state: "ME", district: district_number, cycle: 2026,
                 slug: slug, baseline_margin: -6.0)
  end

  test "a district whose qualifying polls all measure one matchup averages normally" do
    race = district("house-2026-me-02-clean", 2)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:golden|rep:lepage", results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:golden|rep:lepage", results: { dem: 48.0, rep: 46.0 })

    result = @averager.for_race(race)

    assert_predicate result, :polled?
    assert_nil result.reason
    assert_equal 2, result.poll_count
  end

  # Averaging Dunlap-vs-LePage with Baldacci-vs-LePage publishes a margin
  # between two people who are not running against each other.
  test "a district whose qualifying polls span two matchups gets no average, with the reason" do
    race = district("house-2026-me-02-ambiguous", 2)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:dunlap|rep:lepage", results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:baldacci|rep:lepage", results: { dem: 44.0, rep: 50.0 })

    result = @averager.for_race(race)

    assert_not_predicate result, :polled?
    assert_nil result.mean_margin
    assert_equal :ambiguous_matchup, result.reason
    assert_equal [ "baldacci vs lepage", "dunlap vs lepage" ], result.matchups,
                 "named on the two sides being compared, and readable"
    assert_equal 0.0, result.weight, "nothing earned its way into the blend"
    assert_equal 2, result.poll_count, "the polls are still counted — they are on the page"
  end

  # The test runs on what survives the window, so a district resolves itself as
  # its old hypotheticals age out. No migration, no hand-editing.
  test "a matchup that has aged out of the window stops making the district ambiguous" do
    race = district("house-2026-me-02-resolving", 2)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 60, sample_size: 600,
                matchup_key: "dem:dunlap|rep:lepage", results: { dem: 40.0, rep: 55.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 55, sample_size: 600,
                matchup_key: "dem:golden|rep:lepage", results: { dem: 49.0, rep: 45.0 })
    create_poll(pollster: @delta, race: race, field_end: AS_OF - 10, sample_size: 600,
                matchup_key: "dem:golden|rep:lepage", results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: create_pollster("Katahdin Polling"), race: race, field_end: AS_OF - 3,
                sample_size: 600, matchup_key: "dem:golden|rep:lepage", results: { dem: 51.0, rep: 44.0 })

    assert_equal :ambiguous_matchup,
                 Forecast::Averager.new(as_of: AS_OF - 50).for_race(race).reason,
                 "when the two old matchups were the recent ones, the district was ambiguous"

    today = @averager.for_race(race)
    assert_predicate today, :polled?, "the two recent polls agree, and the old ones are out of the window"
    assert_equal 2, today.poll_count
  end

  # Three tables from one pollster on one day are three matchups on the page
  # and one poll in the average.
  test "the one-per-pollster cut runs before the matchup test, not after" do
    race = district("house-2026-me-02-samepollster", 2)
    3.times do |index|
      create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                  matchup_key: "dem:rival#{index}|rep:lepage", results: { dem: 50.0 - index, rep: 44.0 })
    end

    result = @averager.for_race(race)

    assert_predicate result, :polled?
    assert_equal 1, result.poll_count
  end

  # The rule reads on the polls, not on the chamber. A Senate race gets its
  # hypotheticals the same way a district does — through a party slot with no
  # seeded candidate to match against — so it is held to the same test.
  # South Carolina's page carries Annie Andrews against eight different
  # Republicans.
  test "a Senate race whose polls span two matchups falls back too" do
    race = senate_race_for_matchups
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:andrews|rep:norman", results: { dem: 44.0, rep: 50.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:andrews|rep:sanford", results: { dem: 43.0, rep: 49.0 })

    result = @averager.for_race(race)

    assert_not_predicate result, :polled?
    assert_equal :ambiguous_matchup, result.reason
    assert_equal [ "andrews vs norman", "andrews vs sanford" ], result.matchups
  end

  # Montana's live case, and the reason the key is per party slot rather than a
  # flat list of names: the same two people, polled two-way and three-way.
  # Offering a third option changes the numbers, not who is being compared.
  test "a third candidate on the ballot does not make a race ambiguous" do
    race = senate_race_for_matchups
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:bankhead|rep:alme", results: { dem: 44.0, rep: 50.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:bankhead|ind:bodnar|rep:alme", results: { dem: 41.0, rep: 47.0, ind: 8.0 })

    result = @averager.for_race(race)

    assert_predicate result, :polled?
    assert_nil result.reason
  end

  # South Dakota and Idaho both put an independent in the anti-Republican slot
  # with a Democrat also on the page. The pair that matters is the one the
  # average compares, and nobody else on the row counts.
  test "the pair compared is the one the sides name, not everyone on the row" do
    race = senate_race_for_matchups
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "ind:bengs|rep:rounds", results: { ind: 40.0, rep: 52.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:beaudion|ind:bengs|rep:rounds", results: { ind: 38.0, rep: 50.0, dem: 6.0 })

    result = @averager.for_race(race, side_a: :ind, side_b: :rep)

    assert_predicate result, :polled?, "both measure Bengs against Rounds"
    assert_nil result.reason
  end

  test "a poll whose key does not name both sides is not evidence of ambiguity" do
    race = senate_race_for_matchups
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:andrews|rep:norman", results: { dem: 44.0, rep: 50.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: nil, results: { dem: 43.0, rep: 49.0 })

    result = @averager.for_race(race)

    assert_predicate result, :polled?
    assert_equal 2, result.poll_count
  end

  def senate_race_for_matchups
    Race.create!(office: :senate, state: "MT", cycle: 2026,
                 slug: "senate-matchups-#{SecureRandom.hex(4)}", lean: -12.0)
  end

  test "the generic ballot carries no matchup and is never called ambiguous" do
    create_poll(pollster: @beacon, field_end: AS_OF - 1, sample_size: 600, results: { dem: 49.0, rep: 44.0 })
    create_poll(pollster: @cardinal, field_end: AS_OF - 2, sample_size: 600, results: { dem: 47.0, rep: 46.0 })

    result = @averager.for_generic_ballot

    assert_predicate result, :polled?
    assert_nil result.reason
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
