require "test_helper"

# Every expected number below is worked out by hand from the published
# formulas and written in as a literal, so an implementation change cannot
# quietly move the goalposts:
#
#   comparison weight = exp(-ln2 × |field_end − t| / 14) × sqrt(min(n, 1500) / 600)
#   residual          = margin − weighted mean of OTHER houses' margins
#   effect_shrunk     = clamp(effect_raw × n / (n + 5), ±3.0)
#
class Forecast::HouseEffectsTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 8, 1)

  setup do
    @beacon = pollsters(:beacon_polling)
    @cardinal = pollsters(:cardinal_research)
    @delta = pollsters(:delta_metrics)
    @katahdin = create_pollster("Katahdin Polling")
    # Every expected number below is hand-computed from the polls the test
    # itself creates. The three fixture polls — Delta's generic ballot and
    # Beacon's and Cardinal's Maine pair — would join those windows and make
    # the arithmetic unreproducible, so this starts from an empty corpus.
    Poll.destroy_all
  end

  def effects_for(pollster, as_of: AS_OF)
    Forecast::HouseEffects.call(as_of: as_of).effects.find { |e| e.pollster_id == pollster.id }
  end

  # --- The residual golden -------------------------------------------------

  # Beacon at +6.0, fielded 20 days before the run. Three other houses inside
  # its ±45-day window:
  #   Cardinal  +3.0, 14 days before it, n=600  → w = 0.5   × 1.0       = 0.5000000
  #   Delta     +1.0, same day,          n=1500 → w = 1.0   × 1.5811388 = 1.5811388
  #   Katahdin  −4.0, 14 days after it,  n=400  → w = 0.5   × 0.8164966 = 0.4082483
  # W = 2.4893871, weighted sum = 1.5 + 1.5811388 − 1.6329932 = 1.4481457,
  # comparison average = 0.5817278, residual = 6.0 − 0.5817278 = 5.4182722.
  test "a residual is the poll's margin minus a weighted average of the other houses" do
    subject = create_poll(pollster: @beacon, field_end: AS_OF - 20, sample_size: 600,
                          results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: @cardinal, field_end: AS_OF - 34, sample_size: 600, results: { dem: 48.0, rep: 45.0 })
    create_poll(pollster: @delta, field_end: AS_OF - 20, sample_size: 1500, results: { dem: 47.0, rep: 46.0 })
    create_poll(pollster: @katahdin, field_end: AS_OF - 6, sample_size: 400, results: { dem: 45.0, rep: 49.0 })

    effect = effects_for(@beacon)

    assert_equal 1, effect.residual_count
    assert_in_delta 5.4183, effect.effect_raw, 0.00005
    assert_in_delta 5.4182722, effect.effect_raw, 1e-7
    # ... and one residual is shrunk hard: 5.4182722 × 1/(1+5).
    assert_in_delta 0.9030454, effect.effect_shrunk, 1e-7
    assert_not effect.applied, "one residual is under min_polls_to_apply"
    assert_predicate subject.reload, :persisted?
  end

  test "the comparison average leaves out the pollster's own polls" do
    # Beacon polls the same quantity three times and nobody else polls it at
    # all. There is no field to compare against, so there is no residual —
    # rather than a residual of zero, which is what comparing Beacon against
    # itself would produce.
    3.times do |index|
      create_poll(pollster: @beacon, field_end: AS_OF - (index * 5), sample_size: 600,
                  results: { dem: 60.0, rep: 30.0 })
    end

    result = Forecast::HouseEffects.call(as_of: AS_OF)

    assert_nil result.effects.find { |e| e.pollster_id == @beacon.id }
    assert_equal 3, result.skipped[:no_comparison]
  end

  # A house that polls twice as often as everyone else must not become the
  # field. Delta polls three times inside Beacon's window; only the nearest
  # counts, so the comparison is Cardinal's +2.0, Delta's +2.0 and Katahdin's
  # +2.0 — an even 2.0 — not a Delta-weighted average of +2.0, −10.0 and −10.0.
  test "a prolific house contributes one poll to the comparison, not all of them" do
    create_poll(pollster: @beacon, field_end: AS_OF - 20, sample_size: 600, results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: @cardinal, field_end: AS_OF - 20, sample_size: 600, results: { dem: 48.0, rep: 46.0 })
    create_poll(pollster: @katahdin, field_end: AS_OF - 20, sample_size: 600, results: { dem: 48.0, rep: 46.0 })
    create_poll(pollster: @delta, field_end: AS_OF - 20, sample_size: 600, results: { dem: 48.0, rep: 46.0 })
    create_poll(pollster: @delta, field_end: AS_OF - 21, sample_size: 1500, results: { dem: 40.0, rep: 50.0 })
    create_poll(pollster: @delta, field_end: AS_OF - 19, sample_size: 1500, results: { dem: 40.0, rep: 50.0 })

    assert_in_delta 4.0, effects_for(@beacon).effect_raw, 1e-9
  end

  # --- The window ----------------------------------------------------------

  test "a comparison poll exactly on the window boundary is inside it, and one day further is not" do
    create_poll(pollster: @beacon, field_end: AS_OF - 50, sample_size: 600, results: { dem: 50.0, rep: 44.0 })

    with_params(house_effects: { min_comparison_pollsters: 1 }) do
      inside = create_poll(pollster: @cardinal, field_end: AS_OF - 95, sample_size: 600,
                           results: { dem: 46.0, rep: 44.0 })
      assert_equal 45, (inside.field_end - (AS_OF - 50)).to_i.abs
      assert_in_delta 4.0, effects_for(@beacon).effect_raw, 1e-9

      inside.update!(field_end: AS_OF - 96)
      assert_nil effects_for(@beacon), "46 days away is outside the window, and nothing else is in it"
    end
  end

  # The window reaches both ways. A backward-only window would sit weeks
  # behind every poll and charge each pollster for the movement in between.
  test "the window is symmetric — a later poll counts as much as an earlier one" do
    create_poll(pollster: @beacon, field_end: AS_OF - 50, sample_size: 600, results: { dem: 50.0, rep: 44.0 })

    with_params(house_effects: { min_comparison_pollsters: 1 }) do
      later = create_poll(pollster: @cardinal, field_end: AS_OF - 40, sample_size: 600,
                          results: { dem: 46.0, rep: 44.0 })
      after = effects_for(@beacon).effect_raw

      later.update!(field_end: AS_OF - 60)
      assert_in_delta after, effects_for(@beacon).effect_raw, 1e-9
    end
  end

  # --- Eligibility ---------------------------------------------------------

  # Phase 8's rule. A race whose polls in the window disagree about who is
  # running has no single contest to average, and a residual measured there
  # would be part matchup difference and part house effect with no way to tell
  # which — then carried into every average that pollster touches.
  test "polls in a race whose window spans two matchups produce no residuals" do
    race = Race.create!(office: :house, state: "ME", district: 2, cycle: 2026,
                        slug: "house-me-02-house-effects", baseline_margin: -6.0)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:dunlap|rep:lepage", results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 6, sample_size: 600,
                matchup_key: "dem:baldacci|rep:lepage", results: { dem: 44.0, rep: 50.0 })
    create_poll(pollster: @delta, race: race, field_end: AS_OF - 7, sample_size: 600,
                matchup_key: "dem:dunlap|rep:lepage", results: { dem: 47.0, rep: 47.0 })
    create_poll(pollster: @katahdin, race: race, field_end: AS_OF - 8, sample_size: 600,
                matchup_key: "dem:dunlap|rep:lepage", results: { dem: 46.0, rep: 48.0 })

    result = Forecast::HouseEffects.call(as_of: AS_OF)

    assert_empty result.effects, "not one of the four houses gets an estimate out of this race"
    assert_equal 4, result.skipped[:ambiguous_matchup]
  end

  # The same rule the averager applies: a Senate race gets its hypotheticals
  # through a party slot with no seeded candidate, exactly as a district does.
  test "the ambiguity rule reads on Senate races too" do
    race = Race.create!(office: :senate, state: "SC", cycle: 2026, slug: "senate-sc-house-effects", lean: -10.0)
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 5, sample_size: 600,
                matchup_key: "dem:andrews|rep:norman", results: { dem: 44.0, rep: 50.0 })
    create_poll(pollster: @cardinal, race: race, field_end: AS_OF - 6, sample_size: 600,
                matchup_key: "dem:andrews|rep:sanford", results: { dem: 43.0, rep: 49.0 })
    create_poll(pollster: @delta, race: race, field_end: AS_OF - 7, sample_size: 600,
                matchup_key: "dem:andrews|rep:norman", results: { dem: 45.0, rep: 48.0 })

    assert_empty Forecast::HouseEffects.call(as_of: AS_OF).effects
  end

  test "a poll missing one of the two sides yields no residual and does not enter anyone else's field" do
    create_poll(pollster: @beacon, field_end: AS_OF - 20, sample_size: 600, results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: @cardinal, field_end: AS_OF - 20, sample_size: 600, results: { dem: 48.0, rep: 46.0 })
    create_poll(pollster: @katahdin, field_end: AS_OF - 20, sample_size: 600, results: { dem: 48.0, rep: 46.0 })
    create_poll(pollster: @delta, field_end: AS_OF - 20, sample_size: 600, results: { dem: 48.0, rep: 46.0 })
    one_sided = create_pollster("One Sided Research")
    create_poll(pollster: one_sided, field_end: AS_OF - 20, sample_size: 600, results: { dem: 90.0 })

    result = Forecast::HouseEffects.call(as_of: AS_OF)

    assert_nil result.effects.find { |e| e.pollster_id == one_sided.id }
    assert_equal 1, result.skipped[:not_measurable]
    # Beacon's +6.0 against a field of three +2.0s. The 90-point row never
    # reached the average.
    assert_in_delta 4.0, effects_for(@beacon).effect_raw, 1e-9
  end

  test "a poll against a placeholder opponent is not evidence about anybody's lean" do
    race = Race.create!(office: :house, state: "ME", district: 3, cycle: 2026,
                        slug: "house-me-03-placeholder-effects", baseline_margin: -6.0)
    placeholder = create_pollster("Placeholder Polling")
    create_poll(pollster: placeholder, race: race, field_end: AS_OF - 5, sample_size: 600,
                results: { dem: 20.0, rep: 70.0 },
                raw_payload: { "columns" => { "Jared Golden (D)" => "20%", "Generic Republican" => "70%" } })
    %i[dem rep].each_with_index do |_, index|
      create_poll(pollster: [ @beacon, @cardinal, @delta, @katahdin ][index], race: race,
                  field_end: AS_OF - 5, sample_size: 600, matchup_key: "dem:golden|rep:lepage",
                  results: { dem: 48.0, rep: 46.0 })
    end

    result = Forecast::HouseEffects.call(as_of: AS_OF)

    assert_nil result.effects.find { |e| e.pollster_id == placeholder.id }
    assert_equal 1, result.skipped[:not_measurable]
  end

  # A pairing of two houses is not a field: half of the gap between them is
  # the other one's own lean, and it lands in both estimates equal and
  # opposite. Idaho's two polls, 44 points apart, are the live case.
  test "a residual needs min_comparison_pollsters other houses before it counts" do
    create_poll(pollster: @beacon, field_end: AS_OF - 20, sample_size: 600, results: { dem: 60.0, rep: 16.0 })
    create_poll(pollster: @cardinal, field_end: AS_OF - 14, sample_size: 600, results: { dem: 38.0, rep: 38.0 })

    result = Forecast::HouseEffects.call(as_of: AS_OF)

    assert_empty result.effects
    assert_equal 2, result.skipped[:thin_comparison]

    with_params(house_effects: { min_comparison_pollsters: 1 }) do
      assert_in_delta 44.0, effects_for(@beacon).effect_raw, 1e-9,
                      "and this is the ±44 the rule exists to keep out"
    end
  end

  # A release that publishes a two-way and a three-way version of the same
  # question is one poll. Counting it twice would inflate the residual count
  # that the shrinkage term reads as evidence. Tavern Research's four Montana
  # rows to 2026-07-27 are the live case.
  test "one house's several rows from a single field period count once" do
    flat_field(AS_OF - 20)
    3.times do |index|
      create_poll(pollster: @beacon, field_end: AS_OF - 20, field_start: AS_OF - 23,
                  sample_size: 600, results: { dem: 50.0 - index, rep: 44.0 })
    end

    assert_equal 1, effects_for(@beacon).residual_count
  end

  test "the same house polling on two different days counts twice" do
    flat_field(AS_OF - 20)
    create_poll(pollster: @beacon, field_end: AS_OF - 20, sample_size: 600, results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: @beacon, field_end: AS_OF - 21, sample_size: 600, results: { dem: 50.0, rep: 44.0 })

    assert_equal 2, effects_for(@beacon).residual_count
  end

  test "a poll fielded after the as-of date is not in hand yet" do
    flat_field(AS_OF - 20)
    create_poll(pollster: @beacon, field_end: AS_OF + 1, sample_size: 600, results: { dem: 50.0, rep: 44.0 })

    assert_nil effects_for(@beacon)
  end

  # --- Shrinkage, the cap, and the gate ------------------------------------

  # Against a field that says exactly +2.0 every time, a house that says
  # exactly +4.0 every time has a residual of exactly +2.0 every time,
  # whatever the weights. That makes effect_raw exactly 2.0 and leaves the
  # shrinkage arithmetic on its own: 2.0 × n / (n + 5).
  { 1 => 0.3333333, 5 => 1.0, 50 => 1.8181818 }.each do |count, expected|
    test "shrinkage at n = #{count}: 2.0 × #{count}/(#{count} + 5) = #{expected}" do
      steady_house(margin: 4.0, days: count)

      effect = effects_for(@beacon)

      assert_equal count, effect.residual_count
      assert_in_delta 2.0, effect.effect_raw, 1e-9
      assert_in_delta expected, effect.effect_shrunk, 1e-7
    end
  end

  test "the shrinkage constant comes from the params file" do
    steady_house(margin: 4.0, days: 5)
    assert_in_delta 1.0, effects_for(@beacon).effect_shrunk, 1e-9

    with_params(house_effects: { shrinkage_k: 15.0 }) do
      assert_in_delta 0.5, effects_for(@beacon).effect_shrunk, 1e-9, "2.0 × 5/(5 + 15)"
    end
  end

  test "the cap clamps a large effect in both directions" do
    steady_house(margin: 22.0, days: 10)
    positive = effects_for(@beacon)
    assert_in_delta 20.0, positive.effect_raw, 1e-9
    assert_in_delta 13.3333333, 20.0 * 10 / 15, 1e-7, "unclamped this would be 13.3"
    assert_in_delta 3.0, positive.effect_shrunk, 1e-9

    Poll.destroy_all
    steady_house(margin: -18.0, days: 10)
    negative = effects_for(@beacon)
    assert_in_delta(-20.0, negative.effect_raw, 1e-9)
    assert_in_delta(-3.0, negative.effect_shrunk, 1e-9)
  end

  test "the cap comes from the params file" do
    steady_house(margin: 22.0, days: 10)
    assert_in_delta 3.0, effects_for(@beacon).effect_shrunk, 1e-9

    with_params(house_effects: { max_effect_pp: 5.0 }) do
      assert_in_delta 5.0, effects_for(@beacon).effect_shrunk, 1e-9
    end
  end

  # The gate decides whether the model acts, never whether a reader sees.
  test "min_polls_to_apply gates whether an effect is applied, not whether it is published" do
    steady_house(margin: 4.0, days: 2)

    effect = effects_for(@beacon)
    assert_equal 2, effect.residual_count
    assert_in_delta 2.0, effect.effect_raw, 1e-9, "the estimate is still made"
    assert_not effect.applied, "and still published — it is simply not acted on"
    assert_empty Forecast::HouseEffects.call(as_of: AS_OF).lookup

    with_params(house_effects: { min_polls_to_apply: 2 }) do
      assert_predicate effects_for(@beacon), :applied
      assert_in_delta 2.0 * 2 / 7, Forecast::HouseEffects.call(as_of: AS_OF).lookup.fetch(@beacon.id), 1e-9
    end
  end

  test "disabled estimates every effect and applies none of them" do
    steady_house(margin: 4.0, days: 10)
    assert_predicate effects_for(@beacon), :applied

    with_params(house_effects: { enabled: false }) do
      result = Forecast::HouseEffects.call(as_of: AS_OF)

      assert_not result.enabled
      assert_operator result.effects.size, :>=, 1, "the estimates are still made and still shown"
      assert_equal 0, result.applied_count
      assert_empty result.lookup
    end
  end

  # --- Pooling across quantities -------------------------------------------

  # A house's lean shows up the same way whatever it polls, so the generic
  # ballot and every race pool into one number.
  test "generic-ballot and race residuals pool into a single effect" do
    flat_field(AS_OF - 20)
    create_poll(pollster: @beacon, field_end: AS_OF - 20, sample_size: 600, results: { dem: 50.0, rep: 44.0 })

    race = races(:senate_maine)
    [ @cardinal, @delta, @katahdin ].each do |pollster|
      create_poll(pollster: pollster, race: race, field_end: AS_OF - 20, sample_size: 600,
                  results: { dem: 48.0, rep: 46.0 })
    end
    create_poll(pollster: @beacon, race: race, field_end: AS_OF - 20, sample_size: 600,
                results: { dem: 49.0, rep: 46.0 })

    effect = effects_for(@beacon)

    assert_equal 2, effect.residual_count, "one from the generic ballot, one from Maine"
    # +4.0 from the generic ballot and +1.0 from Maine, equally weighted
    # (same date, same sample size).
    assert_in_delta 2.5, effect.effect_raw, 1e-9
  end

  test "governor races are outside the board the model forecasts and contribute nothing" do
    governor = Race.create!(office: :governor, state: "ME", cycle: 2026, slug: "governor-me-house-effects", lean: 3.5)
    [ @cardinal, @delta, @katahdin ].each do |pollster|
      create_poll(pollster: pollster, race: governor, field_end: AS_OF - 20, sample_size: 600,
                  results: { dem: 48.0, rep: 46.0 })
    end
    create_poll(pollster: @beacon, race: governor, field_end: AS_OF - 20, sample_size: 600,
                results: { dem: 60.0, rep: 30.0 })

    assert_empty Forecast::HouseEffects.call(as_of: AS_OF).effects
  end

  # --- Recency -------------------------------------------------------------

  # Half-lives are what make a house effect describe a house's recent
  # behaviour rather than its behaviour last year, and this one is its own
  # parameter rather than the averager's 14 days — see the note in
  # config/model_params.yml.
  test "an old residual counts for less than a recent one, on the residual half-life" do
    flat_field(AS_OF - 10)
    flat_field(AS_OF - 190)
    create_poll(pollster: @beacon, field_end: AS_OF - 10, sample_size: 600, results: { dem: 50.0, rep: 44.0 })
    create_poll(pollster: @beacon, field_end: AS_OF - 190, sample_size: 600, results: { dem: 42.0, rep: 46.0 })

    # The two polls are 180 days apart — exactly one residual half-life — so
    # the recent one weighs exactly twice the old one, whatever the constants
    # work out to numerically. Recent residual +4.0 at weight 2w, old residual
    # −6.0 at weight w: (4 × 2 − 6 × 1) / 3 = 2/3.
    assert_in_delta 2.0 / 3.0, effects_for(@beacon).effect_raw, 1e-9

    # On a much shorter half-life the recent poll would swamp the old one.
    with_params(house_effects: { residual_half_life_days: 14 }) do
      assert_operator effects_for(@beacon).effect_raw, :>, 3.5
    end
  end

  private
    # Three other houses all saying exactly +2.0 on one date — a flat field,
    # so a subject's residual is its own margin minus 2.0 exactly, whatever
    # the weights work out to.
    def flat_field(field_end)
      [ @cardinal, @delta, @katahdin ].each do |pollster|
        create_poll(pollster: pollster, field_end: field_end, sample_size: 600, results: { dem: 48.0, rep: 46.0 })
      end
    end

    # Beacon polling `margin` against that flat field on `days` separate
    # dates, all far enough apart to be distinct field periods and all inside
    # each other's comparison windows.
    def steady_house(margin:, days:)
      days.times do |index|
        date = AS_OF - 20 - index
        flat_field(date)
        create_poll(pollster: @beacon, field_end: date, sample_size: 600,
                    results: { dem: 46.0 + margin, rep: 46.0 })
      end
    end
end
