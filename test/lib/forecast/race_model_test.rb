require "test_helper"

class Forecast::RaceModelTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 8, 1)

  setup do
    @averager = Forecast::Averager.new(as_of: AS_OF)
    @beacon = pollsters(:beacon_polling)
    @cardinal = pollsters(:cardinal_research)
    @delta = pollsters(:delta_metrics)
  end

  # --- Senate prior -------------------------------------------------------
  # lean + national_env + 1.5 × incumbent_direction

  test "a Democratic incumbent on the ballot is worth +1.5" do
    race = senate_race(lean: 4.0, incumbent_party: :dem, open_seat: false)

    assert_in_delta 7.5, model(race, national_env: 2.0).prior, 1e-9
  end

  test "a Republican incumbent on the ballot is worth -1.5" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: false)

    assert_in_delta 4.5, model(race, national_env: 2.0).prior, 1e-9
  end

  test "an open seat gets no incumbency term whichever party held it" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)

    assert_in_delta 6.0, model(race, national_env: 2.0).prior, 1e-9
  end

  test "an independent incumbent gets no incumbency term either" do
    race = senate_race(lean: 4.0, incumbent_party: :ind, open_seat: false)

    assert_in_delta 6.0, model(race, national_env: 2.0).prior, 1e-9
  end

  # South Carolina, live in 2026: the appointed incumbent is running but the
  # Republican nomination is unsettled, so no candidate row is flagged
  # incumbent. The seat is still not open and the incumbency term still applies.
  test "an appointed incumbent counts even with no candidate row to point at" do
    race = senate_race(lean: -16.0, incumbent_party: :rep, open_seat: false)
    assert_empty race.candidates

    assert_in_delta(-15.5, model(race, national_env: 2.0).prior, 1e-9)
  end

  test "the national environment moves every senate prior one for one" do
    race = senate_race(lean: 0.0, incumbent_party: :rep, open_seat: true)

    assert_in_delta(-3.0, model(race, national_env: -3.0).prior, 1e-9)
    assert_in_delta 5.0, model(race, national_env: 5.0).prior, 1e-9
  end

  # --- House prior --------------------------------------------------------
  # baseline + (national_env − house_national_margin_2024) + open_seat_term

  test "a house district swings by the change in the national environment since 2024" do
    race = house_race(baseline_margin: 2.7)

    # 2.7 + (2.0 − −2.6) = 7.3
    assert_in_delta 7.3, model(race, national_env: 2.0).prior, 1e-9
    # A national environment equal to 2024's leaves the district where it was.
    assert_in_delta 2.7, model(race, national_env: -2.6).prior, 1e-9
  end

  # A district whose polls disagree about who is running has polls but no
  # usable average, and the model has to treat it as the unpolled race it
  # effectively is rather than blending a margin between people who are not
  # running against each other.
  test "a district whose polls span two matchups rests on fundamentals" do
    race = house_race(baseline_margin: 2.7, slug: "house-ambiguous-matchup")
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:dunlap|rep:lepage", results: { dem: 55.0, rep: 40.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:baldacci|rep:lepage", results: { dem: 40.0, rep: 55.0 })

    subject = model(race, national_env: 2.0)

    assert_not_predicate subject, :polled?
    assert_equal :ambiguous_matchup, subject.average.reason
    assert_in_delta 7.3, subject.mu, 1e-9, "mu is the prior, untouched by either matchup"
    assert_in_delta 0.0, subject.blend_weight, 1e-9
    assert_in_delta 0.0, subject.to_entry.weight, 1e-9
  end

  # Identical treatment for a Senate race, which matters because its sigma
  # moves too: an ambiguous race is an unpolled race, and sigma_state_polled
  # would be claiming a precision the polls cannot supply.
  test "a Senate race whose polls span two matchups rests on fundamentals, at the unpolled sigma" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: false, slug: "senate-ambiguous-matchup")
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:andrews|rep:norman", results: { dem: 55.0, rep: 40.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:andrews|rep:sanford", results: { dem: 40.0, rep: 55.0 })

    subject = model(race, national_env: 2.0)

    assert_not_predicate subject, :polled?
    assert_equal :ambiguous_matchup, subject.average.reason
    assert_in_delta 4.5, subject.mu, 1e-9, "the prior, untouched by either matchup"
    assert_in_delta 0.0, subject.blend_weight, 1e-9
    assert_equal :sigma_state_unpolled, subject.sigma_key
    assert_in_delta Pol::Params.fetch!(:error_model, :sigma_state_unpolled), subject.sigma, 1e-9
  end

  test "a Senate race whose polls agree keeps the polled sigma" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: false, slug: "senate-single-matchup")
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:andrews|rep:norman", results: { dem: 55.0, rep: 40.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:andrews|rep:norman", results: { dem: 53.0, rep: 42.0 })

    subject = model(race, national_env: 2.0)

    assert_predicate subject, :polled?
    assert_equal :sigma_state_polled, subject.sigma_key
  end

  test "a district whose polls agree on one matchup blends them as usual" do
    race = house_race(baseline_margin: 2.7, slug: "house-single-matchup")
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 3, sample_size: 600,
                matchup_key: "dem:golden|rep:lepage", results: { dem: 55.0, rep: 40.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:golden|rep:lepage", results: { dem: 53.0, rep: 42.0 })

    subject = model(race, national_env: 2.0)

    assert_predicate subject, :polled?
    assert_operator subject.mu, :>, 7.3, "the polls pull it above the prior"
  end

  # open_seat is false for all 435 districts in v1 (no 2026 House incumbency
  # data is seeded), so this term is always zero today. These two tests pin
  # both halves: inert now, correctly signed the day the data arrives.
  test "the house open-seat term is zero while no district is marked open" do
    assert_equal 0, Race.house.where(open_seat: true).count, "fixtures should match the live board"

    race = house_race(baseline_margin: 2.7, open_seat: false, incumbent_party: :dem)
    assert_in_delta 7.3, model(race, national_env: 2.0).prior, 1e-9
  end

  test "an open house seat docks the retiring party's incumbency advantage" do
    dem_held = house_race(baseline_margin: 2.7, open_seat: true, incumbent_party: :dem, slug: "house-open-dem")
    rep_held = house_race(baseline_margin: 2.7, open_seat: true, incumbent_party: :rep, slug: "house-open-rep")
    unknown = house_race(baseline_margin: 2.7, open_seat: true, incumbent_party: nil, slug: "house-open-unknown")

    assert_in_delta 5.8, model(dem_held, national_env: 2.0).prior, 1e-9
    assert_in_delta 8.8, model(rep_held, national_env: 2.0).prior, 1e-9
    assert_in_delta 7.3, model(unknown, national_env: 2.0).prior, 1e-9
  end

  # --- Blend --------------------------------------------------------------
  # w = min(1, W / 3.0); mu = w × average + (1 − w) × prior

  test "with no polls the blend weight is zero and mu is the prior" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)
    subject = model(race, national_env: 2.0)

    assert_equal 0.0, subject.blend_weight
    assert_in_delta 6.0, subject.mu, 1e-9
    refute_predicate subject, :polled?
  end

  # One poll, age 0, n = 1350: weight = sqrt(1350/600) = 1.5, so w = 0.5 and mu
  # lands exactly halfway between the prior (6.0) and the average (+10.0).
  test "a half-saturated poll average splits the difference with the prior" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF, sample_size: 1350,
                results: { dem: 53.0, rep: 43.0 })
    subject = model(race, national_env: 2.0)

    assert_in_delta 1.5, subject.average.weight, 1e-9
    assert_in_delta 0.5, subject.blend_weight, 1e-9
    assert_in_delta 8.0, subject.mu, 1e-9
  end

  # Three fresh 600-person polls weigh 1.0 each: W = 3.0 saturates the blend
  # and the prior drops out entirely.
  test "a saturated poll average takes over from the prior" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)
    [ @beacon, @cardinal, @delta ].each do |pollster|
      create_poll(pollster: pollster, race: race, field_end: AS_OF, sample_size: 600,
                  results: { dem: 53.0, rep: 43.0 })
    end
    subject = model(race, national_env: 2.0)

    assert_in_delta 3.0, subject.average.weight, 1e-9
    assert_equal 1.0, subject.blend_weight
    assert_in_delta 10.0, subject.mu, 1e-9
  end

  test "the blend weight never exceeds one however many polls pile up" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)
    6.times do |index|
      create_poll(pollster: create_pollster("Saturating Poll #{index}"), race: race, field_end: AS_OF,
                  sample_size: 1500, results: { dem: 53.0, rep: 43.0 })
    end
    subject = model(race, national_env: 2.0)

    assert_equal 1.0, subject.blend_weight
    assert_in_delta 10.0, subject.mu, 1e-9
  end

  # The blend must never be handed a nil mean to multiply. Polls that carry no
  # weight leave the race on its prior, exactly as no polls would.
  test "polls that carry no weight leave the race on its prior" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 400, sample_size: 600,
                results: { dem: 90.0, rep: 5.0 })
    subject = model(race, national_env: 2.0)

    refute_predicate subject, :polled?
    assert_equal 0.0, subject.blend_weight
    assert_in_delta 6.0, subject.mu, 1e-9
    assert_equal :sigma_state_unpolled, subject.sigma_key
  end

  test "a house district blends its own polls the same way" do
    race = house_race(baseline_margin: 2.7)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF, sample_size: 1350,
                results: { dem: 51.0, rep: 45.0 })
    subject = model(race, national_env: 2.0)

    # prior 7.3, average +6.0, w = 0.5
    assert_in_delta 0.5, subject.blend_weight, 1e-9
    assert_in_delta 6.65, subject.mu, 1e-9
  end

  # --- Sigmas -------------------------------------------------------------

  test "an unpolled senate race carries the wider unpolled sigma" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)

    assert_equal :sigma_state_unpolled, model(race, national_env: 0.0).sigma_key
    assert_in_delta Pol::Params.fetch!(:error_model, :sigma_state_unpolled), model(race, national_env: 0.0).sigma, 1e-9
  end

  test "a polled senate race carries the polled sigma" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF, sample_size: 600, results: { dem: 50.0, rep: 45.0 })

    assert_equal :sigma_state_polled, model(race, national_env: 0.0).sigma_key
  end

  test "a house district always carries the district sigma, polled or not" do
    race = house_race(baseline_margin: 2.7)

    assert_equal :sigma_district, model(race, national_env: 0.0).sigma_key

    create_poll(pollster: @beacon, race: race, field_end: AS_OF, sample_size: 600, results: { dem: 50.0, rep: 45.0 })
    assert_equal :sigma_district, model(race, national_env: 0.0).sigma_key
  end

  # --- Sides --------------------------------------------------------------

  test "a two-party race is a Democrat against a Republican" do
    race = senate_race(lean: 0.0, incumbent_party: :rep, open_seat: false)
    race.candidates.create!(name: "Ada Dean", party: :dem)
    race.candidates.create!(name: "Rex Poole", party: :rep, incumbent: true)
    subject = model(race, national_env: 0.0)

    assert_equal [ :dem, :dem, "Ada Dean" ], subject.side_a.to_a
    assert_equal [ :rep, :rep, "Rex Poole" ], subject.side_b.to_a
  end

  # Nebraska: Dan Osborn, an independent who has said he would caucus with
  # neither party, against Pete Ricketts, with no Democrat on the ballot.
  test "with no Democrat running an uncommitted independent takes side A" do
    race = senate_race(lean: -21.0, incumbent_party: :rep, open_seat: false)
    race.candidates.create!(name: "Pete Ricketts", party: :rep, incumbent: true)
    race.candidates.create!(name: "Dan Osborn", party: :ind, caucus_with: nil)
    subject = model(race, national_env: 0.0)

    assert_equal [ :ind, :uncommitted, "Dan Osborn" ], subject.side_a.to_a
    assert_equal [ :rep, :rep, "Pete Ricketts" ], subject.side_b.to_a
  end

  test "an independent who has declared a caucus is counted in that caucus" do
    race = senate_race(lean: -10.0, incumbent_party: :rep, open_seat: false)
    race.candidates.create!(name: "Rex Poole", party: :rep, incumbent: true)
    race.candidates.create!(name: "Ida Nunn", party: :ind, caucus_with: :dem)

    assert_equal [ :ind, :dem, "Ida Nunn" ], model(race, national_env: 0.0).side_a.to_a
  end

  # Mississippi and Montana both have a Democrat and an independent. The
  # independent is a spoiler, not a side: the modelled contest stays D vs R.
  test "an independent alongside a Democrat does not displace them" do
    race = senate_race(lean: -10.0, incumbent_party: :rep, open_seat: false)
    race.candidates.create!(name: "Ada Dean", party: :dem)
    race.candidates.create!(name: "Rex Poole", party: :rep, incumbent: true)
    race.candidates.create!(name: "Ty Loner", party: :ind)
    subject = model(race, national_env: 0.0)

    assert_equal :dem, subject.side_a.party
    assert_equal :rep, subject.side_b.party
  end

  # Minnesota: both primaries are still open, so neither nominee has a row.
  # The race is still a Democrat against a Republican; we just cannot name them.
  test "an unsettled nomination leaves the side nameless, not empty" do
    race = senate_race(lean: 4.0, incumbent_party: :dem, open_seat: true)

    subject = model(race, national_env: 0.0)
    assert_equal [ :dem, :dem, nil ], subject.side_a.to_a
    assert_equal [ :rep, :rep, nil ], subject.side_b.to_a
  end

  test "the sides decide which poll columns the average reads" do
    race = senate_race(lean: -21.0, incumbent_party: :rep, open_seat: false)
    race.candidates.create!(name: "Pete Ricketts", party: :rep, incumbent: true)
    race.candidates.create!(name: "Dan Osborn", party: :ind)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF, sample_size: 600,
                results: { ind: 47.0, rep: 42.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF, sample_size: 600,
                results: { dem: 39.0, rep: 49.0 })

    subject = model(race, national_env: 0.0)
    assert_equal 1, subject.average.poll_count
    assert_equal 1, subject.average.skipped_count
    assert_in_delta 5.0, subject.average.mean_margin, 1e-9
  end

  # --- Degenerate sides (M5) -----------------------------------------------

  # Two independents and nobody else: side_a claims the lower-id independent,
  # and side_b's fallback has no Republican and no OTHER minor candidate left
  # to exclude its way to — so both sides land on :ind. Forecast::Averager
  # refuses to average a side against itself; this proves RaceModel absorbs
  # that instead of raising, so one malformed race cannot fail a whole run.
  test "two independents and no major-party candidate is treated as unpolled rather than raising" do
    race = senate_race(lean: 0.0, incumbent_party: :ind, open_seat: false)
    race.candidates.create!(name: "Ty Loner", party: :ind)
    race.candidates.create!(name: "Cass Freeman", party: :ind)
    subject = model(race, national_env: 0.0)

    assert_equal :ind, subject.side_a.party
    assert_equal :ind, subject.side_b.party

    entry = nil
    assert_nothing_raised { entry = subject.to_entry }

    refute_predicate subject, :polled?
    assert_in_delta subject.prior, subject.mu, 1e-9
    assert_equal :sigma_state_unpolled, subject.sigma_key
    assert_equal 0.0, entry.weight
  end

  # A normal two-independent-free race is unaffected: the guard only fires
  # when side_a and side_b actually collide.
  test "a normal contested race is unaffected by the degenerate-sides guard" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF, sample_size: 1350,
                results: { dem: 53.0, rep: 43.0 })
    subject = model(race, national_env: 2.0)

    assert_predicate subject, :polled?
    assert_in_delta 8.0, subject.mu, 1e-9
  end

  # --- Uncontested --------------------------------------------------------

  test "an uncontested race has one certain winner and takes no noise" do
    race = senate_race(lean: 4.0, incumbent_party: :dem, open_seat: false, uncontested: true, uncontested_party: :dem)
    subject = model(race, national_env: 0.0)

    assert_equal :dem, subject.certain_side.party
    assert_equal :dem, subject.certain_side.caucus
    assert_equal subject.certain_side, subject.to_entry.certain
  end

  test "an uncontested Republican seat resolves to side B" do
    race = senate_race(lean: -20.0, incumbent_party: :rep, open_seat: false, uncontested: true, uncontested_party: :rep)

    assert_equal :rep, model(race, national_env: 0.0).certain_side.party
  end

  test "an uncontested independent keeps their own caucus" do
    race = senate_race(lean: 0.0, incumbent_party: :ind, open_seat: false, uncontested: true, uncontested_party: :ind)
    race.candidates.create!(name: "Ida Nunn", party: :ind, caucus_with: :rep)

    certain = model(race, national_env: 0.0).certain_side
    assert_equal :ind, certain.party
    assert_equal :rep, certain.caucus
  end

  test "uncontested with no party recorded is treated as contested, not as a certainty" do
    race = senate_race(lean: 4.0, incumbent_party: :dem, open_seat: false, uncontested: true, uncontested_party: nil)

    assert_nil model(race, national_env: 0.0).certain_side
  end

  test "a contested race has no certain winner" do
    race = senate_race(lean: 0.0, incumbent_party: :rep, open_seat: false)

    assert_nil model(race, national_env: 0.0).certain_side
  end

  # --- Entry --------------------------------------------------------------

  test "to_entry hands the simulator everything it needs and no ActiveRecord" do
    race = senate_race(lean: 4.0, incumbent_party: :rep, open_seat: true)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF, sample_size: 1350, results: { dem: 53.0, rep: 43.0 })

    entry = model(race, national_env: 2.0).to_entry

    assert_equal race.id, entry.race_id
    assert_equal :senate, entry.chamber
    assert_in_delta 8.0, entry.mu, 1e-9
    assert_in_delta Pol::Params.fetch!(:error_model, :sigma_state_polled), entry.sigma, 1e-9
    assert_in_delta 1.5, entry.weight, 1e-9
    assert_nil entry.certain
  end

  test "a house race reports the house chamber" do
    assert_equal :house, model(house_race(baseline_margin: 0.0), national_env: 0.0).to_entry.chamber
  end

  test "a race belonging to no chamber refuses to be simulated into one" do
    governor = Race.create!(office: :governor, state: "OH", cycle: 2026, slug: "governor-oh-2026", lean: 0.0)

    assert_raises(KeyError) { model(governor, national_env: 0.0).to_entry }
  end

  private
    def model(race, national_env:)
      Forecast::RaceModel.new(race: race, national_env: national_env, averager: @averager,
                              polls: race.polls.includes(:poll_results).to_a)
    end

    def senate_race(lean:, incumbent_party:, open_seat:, **attributes)
      Race.create!(
        office: :senate, state: "OH", cycle: 2026, lean: lean,
        incumbent_party: incumbent_party, open_seat: open_seat,
        slug: attributes.delete(:slug) || "senate-test-#{SecureRandom.hex(4)}",
        **attributes
      )
    end

    def house_race(baseline_margin:, **attributes)
      Race.create!(
        office: :house, state: "OH", district: 1, cycle: 2026, baseline_margin: baseline_margin,
        slug: attributes.delete(:slug) || "house-test-#{SecureRandom.hex(4)}",
        **attributes
      )
    end
end
