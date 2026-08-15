require "test_helper"

class RacesControllerTest < ActionDispatch::IntegrationTest
  # --- /senate ---------------------------------------------------------

  test "senate renders every Senate fixture race" do
    get senate_path
    assert_response :success
    assert_select "[data-testid='senate-race-row']", count: Race.senate.count
    assert_select "a[href='#{race_path(races(:senate_maine).slug)}']"
    assert_select "a[href='#{race_path(races(:senate_florida_special).slug)}']"
  end

  test "senate table rows link to their race page" do
    get senate_path
    assert_select "[data-testid='senate-race-row'] a[href='#{race_path(races(:senate_maine).slug)}']"
  end

  test "senate supports sorting by column and toggling direction" do
    get senate_path, params: { sort: "state", dir: "asc" }
    ascending = css_select("[data-testid='senate-race-row']").map { |row| row.css("a").first.text.strip }

    get senate_path, params: { sort: "state", dir: "desc" }
    descending = css_select("[data-testid='senate-race-row']").map { |row| row.css("a").first.text.strip }

    assert_equal ascending, descending.reverse
    assert_select "[data-testid='senate-sort-state']"
  end

  test "senate ignores a nonsense sort param rather than erroring" do
    get senate_path, params: { sort: "'; drop table races;--" }
    assert_response :success
  end

  # --- /house ------------------------------------------------------------

  test "house renders the chamber summary, error-model note and search input" do
    get house_path
    assert_response :success
    assert_select "[data-testid='seat-histogram-house']"
    assert_select "[data-testid='house-error-note']"
    assert_select "[data-testid='house-search-input']"
    refute_match(/overstates certainty/, response.body)
  end

  test "house renders every House fixture race with a data-search attribute for the client-side filter" do
    get house_path
    assert_select "[data-testid='house-race-row']", count: Race.house.count
    assert_select "[data-testid='house-race-row'][data-search]"
  end

  test "house marks an imputed baseline, and does not mark a real one" do
    imputed = Race.create!(
      office: :house, state: "ZZ", district: 1, cycle: 2026, slug: "house-controller-test-imputed",
      baseline_margin: 35.0, baseline_imputed: true
    )

    get house_path

    imputed_row = css_select("[data-testid='house-race-row']").find { |row| row.text.include?(imputed.name) }
    assert imputed_row.css("[data-testid='baseline-imputed-marker']").any?

    real_row = css_select("[data-testid='house-race-row']").find { |row| row.text.include?(races(:house_ny_17).name) }
    assert_empty real_row.css("[data-testid='baseline-imputed-marker']")
  end

  test "house table query count does not scale with the number of districts" do
    baseline = count_queries { get house_path }

    5.times { |i| Race.create!(office: :house, state: "ZZ", district: 50 + i, cycle: 2026, slug: "house-controller-test-extra-#{i}", baseline_margin: 1.0) }

    with_extra_rows = count_queries { get house_path }

    assert_equal baseline, with_extra_rows
  end

  # --- /races/:slug --------------------------------------------------------

  test "show renders a polled race with its candidates, forecast and timeline" do
    get race_path(races(:senate_maine).slug)

    assert_response :success
    assert_select "[data-testid='race-name']", text: races(:senate_maine).name
    assert_select "[data-testid='forecast-detail']"
    assert_select "[data-testid='timeline-chart']"
    assert_select "[data-testid='percentile-interval']"
  end

  test "show 404s cleanly on an unknown slug" do
    get race_path("not-a-real-race")
    assert_response :not_found
    assert_select "[data-testid='not-found']"
  end

  test "show renders the honest unpolled empty state and skips the polls chart/table" do
    get race_path(races(:senate_florida_special).slug)

    assert_response :success
    assert_select "[data-testid='unpolled-empty-state']", text: /No public polling — forecast rests on fundamentals/
    assert_select "[data-testid='polls-scatter-chart']", count: 0
    assert_select "[data-testid='poll-table']", count: 0
  end

  test "show links every poll row to its source_url" do
    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='poll-row']", count: races(:senate_maine).polls.count
    assert_select "[data-testid='poll-source-link'][href='#{polls(:maine_poll_one).source_url}']"
    assert_select "[data-testid='poll-source-link'][href='#{polls(:maine_poll_two).source_url}']"
  end

  test "show renders the polls scatter chart when the race has polls" do
    get race_path(races(:senate_maine).slug)
    assert_select "[data-testid='polls-scatter-chart']"
  end

  # --- Pollster house effects on the poll table (Phase 9) ----------------

  # A reader has to be able to see exactly what the model did to each poll,
  # not just be told that it did something. maine_poll_one is Beacon at
  # 47.5–44.0 (D+3.5); a +1.5 effect leaves D+2.0.
  test "show spells out the adjustment on a poll whose pollster has an applied effect" do
    HouseEffect.create!(model_run: model_runs(:model_run_one), pollster: pollsters(:beacon_polling),
                        effect_raw: 3.0, effect_shrunk: 1.5, residual_count: 9, applied: true)

    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='poll-adjustment']", count: 1
    assert_select "[data-testid='poll-adjustment']", text: /D\+1\.5/, count: 1
    assert_select "[data-testid='poll-adjustment']", text: /D\+2\.0/, count: 1
    assert_select "[data-testid='poll-table']", text: /House adj/
  end

  test "a poll whose pollster has no applied effect shows no adjustment" do
    HouseEffect.create!(model_run: model_runs(:model_run_one), pollster: pollsters(:beacon_polling),
                        effect_raw: 6.0, effect_shrunk: 2.0, residual_count: 1, applied: false)

    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='poll-adjustment']", count: 0
  end

  test "the poll table links its adjustment column to the pollsters page" do
    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='poll-table'] a[href='#{pollsters_path}']"
  end

  # A district whose polls measure contests that cannot all happen has polling
  # and no forecast-grade average. The page has to say both — hiding the polls
  # would be as dishonest as averaging them.
  test "show says why a district with several matchups rests on fundamentals, and keeps its polls" do
    race = races(:house_ny_17)
    ambiguous_district_polls(race)

    get race_path(race.slug)

    assert_select "[data-testid='ambiguous-matchup-note']", text: /2 different matchups/
    assert_select "[data-testid='ambiguous-matchup-note']", text: /rests on fundamentals/
    assert_select "[data-testid='poll-row']", { count: 2 }, "both polls are still on the page"
    assert_select "[data-testid='poll-matchup-heading']", count: 2
    assert_select "[data-testid='poll-matchup-heading'][data-matchup='dem:conley|rep:lawler']"
  end

  # Same note, and the fundamentals it names are the Senate's, not a
  # district's — a state has no 2024 district result to rest on.
  test "show gives a Senate race the Senate wording when its matchups disagree" do
    race = races(:senate_maine)
    race.polls.destroy_all
    ambiguous_district_polls(race)

    get race_path(race.slug)

    assert_select "[data-testid='ambiguous-matchup-note']", text: /the state's partisan lean/
    assert_select "[data-testid='ambiguous-matchup-note']", text: /2 different matchups/
    assert_select "[data-testid='poll-matchup-heading']", count: 2
  end

  test "show gives a district the district wording" do
    ambiguous_district_polls(races(:house_ny_17))

    get race_path(races(:house_ny_17).slug)

    assert_select "[data-testid='ambiguous-matchup-note']", text: /the district's 2024 result/
  end

  test "show leaves a single-matchup race's poll table ungrouped" do
    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='poll-table']"
    assert_select "[data-testid='poll-matchup-heading']", count: 0
    assert_select "[data-testid='ambiguous-matchup-note']", count: 0
  end

  def ambiguous_district_polls(race)
    [ [ "dem:conley|rep:lawler", "Cait Conley (D)", 51.0 ],
      [ "dem:jones|rep:lawler", "Pat Jones (D)", 44.0 ] ].each_with_index do |(key, dem_label, dem_pct), index|
      create_poll(
        pollster: index.zero? ? pollsters(:beacon_polling) : pollsters(:cardinal_research),
        race: race, field_end: Date.current - index, sample_size: 600,
        results: { dem: dem_pct, rep: 45.0 }, matchup_key: key,
        raw_payload: { "columns" => { "Mike Lawler (R)" => "45%", dem_label => "#{dem_pct}%" } }
      )
    end
  end

  test "show renders a graceful no-forecast state for a race with no forecast row" do
    unforecast = Race.create!(office: :senate, state: "ZZ", cycle: 2026, slug: "senate-controller-test-unforecast")

    get race_path(unforecast.slug)

    assert_response :success
    assert_select "[data-testid='forecast-empty']"
  end

  test "show renders a dispatch's byline, plain" do
    get race_path(races(:senate_maine).slug)
    assert_select "[data-testid='dispatch-byline']", text: /Written autonomously by #{Regexp.escape(dispatches(:maine_poll_reaction).model_slug)}/
    assert_select "[data-testid='dispatch-byline']", text: /Updated by the editor/, count: 0
  end

  test "show renders the edited variant of a dispatch's byline when edited_at is present" do
    dispatches(:maine_poll_reaction).update!(edited_at: Time.current)

    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='dispatch-byline']", text: /Updated by the editor/
  end

  # --- Chamber index parity -------------------------------------------------
  # /senate and /house drifted apart when they were specified separately. The
  # tests below pin the chrome both pages are now expected to share. The
  # *columns* deliberately still differ (lean vs 2024 baseline) — that is the
  # point of keeping the two templates separate, so nothing here asserts they
  # are identical, only that neither is missing a feature the other has.

  test "both chamber pages render the summary card, the search box and a sticky header" do
    { senate_path => "senate", house_path => "house" }.each do |path, chamber|
      get path
      assert_response :success

      assert_select "[data-testid='chamber-card-#{chamber}']", { count: 1 }, "#{path} is missing the chamber card"
      assert_select "input[data-table-filter-target='input']", { count: 1 }, "#{path} is missing the search box"
      assert_select "thead th.sticky", { minimum: 1 }, "#{path} is missing a sticky header"
    end
  end

  test "both chamber pages sort by every advertised key without error" do
    { senate_path => Site::SenateTable::SORTS, house_path => Site::HouseTable::SORTS }.each do |path, keys|
      keys.each do |key|
        %w[asc desc].each do |dir|
          get path, params: { sort: key, dir: dir }
          assert_response :success, "#{path}?sort=#{key}&dir=#{dir} failed"
        end
      end
    end
  end

  test "house sort headers link to the house path, not the senate one" do
    get house_path

    assert_select "[data-testid='house-sort-margin']" do |links|
      assert_match %r{\A/house\?}, links.first["href"]
    end
  end

  test "an active sort header offers the opposite direction next" do
    get house_path, params: { sort: "margin", dir: "asc" }
    assert_select "[data-testid='house-sort-margin']" do |links|
      assert_match "dir=desc", links.first["href"]
      assert_match "▲", links.first.text
    end
  end

  # The interaction the parity work created: sorting reloads the page, so a
  # sort link has to carry the reader's client-side filter or the reload
  # silently drops it. The href is written by Stimulus at input time (never
  # server-side — a cached fragment would leak one reader's search into
  # another's links), so what this pins is that the hook the controller needs
  # is present on every sort link.
  test "every sort link is a table-filter target so the client can carry the search across a reload" do
    [ senate_path, house_path ].each do |path|
      get path
      links = css_select("thead a")
      assert_operator links.size, :>=, 5, "#{path} has suspiciously few sort links"
      links.each do |link|
        assert_equal "sortLink", link["data-table-filter-target"],
                     "#{path}: a sort link that Stimulus can't rewrite will drop the reader's filter"
      end
    end
  end

  test "house rows carry the forecast margin and last poll date the parity pass added" do
    run = model_runs(:model_run_one)
    Forecast.create!(model_run: run, race: races(:house_ny_17), p_dem_win: 0.71, p_rep_win: 0.29, mean_margin: 6.4)
    Poll.create!(
      pollster: pollsters(:beacon_polling), race: races(:house_ny_17), field_end: Date.new(2026, 7, 3),
      sample_size: 500, population: :lv, source_url: "https://example.com/house-parity",
      dedup_digest: "house-parity-columns", entry_mode: :manual
    )

    get house_path

    assert_select "[data-testid='house-race-row']", text: /D\+6\.4/
    assert_select "[data-testid='house-race-row']", text: /Jul 3, 2026/
  end

  test "senate rows show the state lean, its fundamentals input" do
    races(:senate_maine).update!(lean: -7.5)

    get senate_path

    assert_select "[data-testid='senate-race-row']", text: /R\+7\.5/
  end

  test "senate search text matches state name, code and the word special" do
    get senate_path

    rows = css_select("[data-testid='senate-race-row']").map { |row| row["data-search"] }

    maine = rows.find { |text| text.include?("maine") }
    assert maine, "no Senate row carries its full state name for the filter"
    assert_includes maine, "me", "the two-letter code should match too"

    special = rows.find { |text| text.include?("special") }
    assert special, "a special election should be findable by typing 'special'"
  end
end
