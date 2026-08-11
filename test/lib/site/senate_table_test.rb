require "test_helper"

class Site::SenateTableTest < ActiveSupport::TestCase
  test "builds one row per Senate race with its forecast, poll count and last poll date" do
    rows = Site::SenateTable.build(sort: nil, direction: "asc").index_by { |row| row.race.id }

    maine = rows.fetch(races(:senate_maine).id)
    assert_equal forecasts(:maine_forecast), maine.forecast
    assert_equal 2, maine.poll_count
    assert_equal Date.new(2026, 7, 24), maine.last_poll_date

    florida = rows.fetch(races(:senate_florida_special).id)
    assert_nil florida.forecast
    assert_equal 0, florida.poll_count
    assert_nil florida.last_poll_date
  end

  test "defaults to sorting by state ascending, and an unknown sort value falls back to it" do
    default = Site::SenateTable.build(sort: nil, direction: "asc").map { |row| row.race.state }
    garbage = Site::SenateTable.build(sort: "not-a-real-column", direction: "asc").map { |row| row.race.state }

    assert_equal %w[FL ME], default
    assert_equal default, garbage
  end

  test "direction: desc reverses whatever sort is in effect" do
    asc = Site::SenateTable.build(sort: "state", direction: "asc").map { |row| row.race.state }
    desc = Site::SenateTable.build(sort: "state", direction: "desc").map { |row| row.race.state }

    assert_equal asc.reverse, desc
  end

  test "sorts by probability, margin, poll count and last-poll date independently" do
    # "probability" sorts by the *leading* side's win probability, which for
    # a two-party race is always >= 0.5 — so distinct p_dem_win values don't
    # automatically give distinct leading-probabilities (a 0.10 dem/0.90 rep
    # split leads at 0.90, not 0.10). Each race below is built with an
    # explicit, independent (p_dem_win, p_rep_win, margin, poll count,
    # last-poll date) tuple so the four sorts are genuinely disambiguated
    # from each other and from alphabetical state order.
    race_a = create_race("AA", state: "AA") # leading prob 0.90, margin 1.0 (lowest), 3 polls, Jan
    race_b = create_race("BB", state: "BB") # leading prob 0.55 (lowest), margin 9.0 (highest), 1 poll, Aug
    race_c = create_race("CC", state: "CC") # leading prob 0.75, margin 5.0, 7 polls, Apr

    forecast_for(race_a, p_dem_win: 0.90, p_rep_win: 0.10, mean_margin: 1.0)
    forecast_for(race_b, p_dem_win: 0.55, p_rep_win: 0.45, mean_margin: 9.0)
    forecast_for(race_c, p_dem_win: 0.25, p_rep_win: 0.75, mean_margin: 5.0)

    create_polls(race_a, count: 3, field_end: Date.new(2026, 1, 1))
    create_polls(race_b, count: 1, field_end: Date.new(2026, 8, 1))
    create_polls(race_c, count: 7, field_end: Date.new(2026, 4, 1))

    states = lambda do |sort|
      Site::SenateTable.build(sort: sort, direction: "asc")
        .map { |row| row.race.state }
        .select { |state| %w[AA BB CC].include?(state) }
    end

    assert_equal %w[BB CC AA], states.call("probability")
    assert_equal %w[AA CC BB], states.call("margin")
    assert_equal %w[BB AA CC], states.call("polls")
    assert_equal %w[AA CC BB], states.call("last_poll")
  end

  test "a bounded number of queries regardless of row count" do
    # Deliberately no warm-up call: an uncounted call immediately before the
    # counted one can make the *second* (identical) query get served from
    # Active Record's query cache and undercount. Measuring cold and busting
    # the cache with real writes before the second measurement keeps both
    # counts honest.
    baseline = count_queries { Site::SenateTable.build(sort: nil, direction: "asc") }

    %w[ZA ZB ZC].each { |state| create_race("extra-senate-#{state}", state: state) }

    with_extra_rows = count_queries { Site::SenateTable.build(sort: nil, direction: "asc") }

    assert_equal baseline, with_extra_rows
    assert_operator baseline, :<=, 6
  end

  private
    def create_race(slug, state:)
      Race.create!(office: :senate, state: state, slug: "senate-table-test-#{slug}", cycle: 2026)
    end

    def forecast_for(race, p_dem_win:, p_rep_win:, mean_margin:)
      Forecast.create!(
        model_run: model_runs(:model_run_one), race: race,
        p_dem_win: p_dem_win, p_rep_win: p_rep_win, mean_margin: mean_margin
      )
    end

    def create_polls(race, count:, field_end:)
      count.times do |i|
        Poll.create!(
          pollster: pollsters(:beacon_polling), race: race, field_end: field_end,
          sample_size: 500, population: :lv, source_url: "https://example.com/t/#{race.slug}/#{i}",
          dedup_digest: "senate-table-test-#{race.slug}-#{i}", entry_mode: :manual
        )
      end
    end
end
