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

  test "each chamber page carries its forecast over time, with its own chamber's runs in the payload" do
    later = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: "2026-10-29 11:00:00")
    ChamberForecast.create!(model_run: later, chamber: :senate, p_dem_control: 0.69, p_rep_control: 0.31, mean_dem_seats: 51.8)
    ChamberForecast.create!(model_run: later, chamber: :house, p_dem_control: 0.97, p_rep_control: 0.03, mean_dem_seats: 241.7)

    { senate_path => [ "senate", %w[55% 69%] ], house_path => [ "house", %w[48% 97%] ] }.each do |path, (chamber, dem_labels)|
      get path
      assert_select "[data-testid='chamber-timeline']" do
        assert_select "h2", text: "Forecast over time"
        assert_select "[data-controller='chamber-timeline-chart'][tabindex='0']"
      end
      payload = JSON.parse(css_select("[data-testid='chamber-timeline'] script[type='application/json']").first.text)
      assert_equal chamber, payload["chamber"]
      assert_equal dem_labels, payload.dig("series", "excl", "dem_labels")
    end
  end

  test "a chamber page with one run says the trend will fill in" do
    get senate_path
    assert_select "[data-testid='chamber-timeline-sparse-note']", text: /1 model run/
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

  test "house table query count does not scale with the number of forecast districts" do
    # The test above adds districts with no forecast, whose margin bar renders
    # "—" without ever asking whose margin it is. A forecast district's bar
    # goes through race_sides, which reads the race's candidates — and every
    # district has a forecast in production, where this ran once per row.
    baseline = count_queries { get house_path }

    5.times do |i|
      race = Race.create!(office: :house, state: "ZZ", district: 60 + i, cycle: 2026, slug: "house-controller-test-forecast-#{i}", baseline_margin: 1.0)
      Forecast.create!(model_run: model_runs(:model_run_one), race: race, p_dem_win: 0.6, p_rep_win: 0.4, mean_margin: 2.0)
    end

    with_forecast_rows = count_queries { get house_path }

    assert_equal baseline, with_forecast_rows
  end

  # --- /races/:slug --------------------------------------------------------

  test "show renders a polled race with its candidates, forecast and timeline" do
    get race_path(races(:senate_maine).slug)

    assert_response :success
    assert_select "[data-testid='race-name']", text: races(:senate_maine).name
    assert_select "[data-analytics-event-name-value='race_viewed']"
    assert_select "[data-testid='race-masthead'] [data-testid='rating-word']", text: "Tossup"
    assert_select "[data-testid='race-masthead'] [data-testid='win-probability']", text: /62%/
    assert_select "[data-testid='forecast-detail']"
    assert_select "[data-testid='timeline-chart']"
    assert_select "[data-testid='percentile-interval']"
  end

  # --- The simulation-count sentence ------------------------------------
  # These three branches are the whole of what a reader is told about how the
  # probability was arrived at, and each states a literal count of simulated
  # worlds — so each is asserted on the rendered string rather than trusted to
  # the helper's unit test.

  test "show states the run's own simulation count, not the configured one" do
    # The fixture run drew 10,000. Raising simulation.n_sims must not relabel
    # a forecast that was never drawn at the new count.
    with_params(simulation: { n_sims: 500_000 }) do
      get race_path(races(:senate_maine).slug)
    end

    assert_response :success
    assert_select "p", text: /the leading side wins 6,200 of 10,000 simulated elections/
    assert_select "p", text: /of 500,000/, count: 0
  end

  test "show gives a favoured race the winning-side wording" do
    forecasts(:maine_forecast).update!(p_dem_win: 0.9527, p_rep_win: 0.0473)

    get race_path(races(:senate_maine).slug)

    assert_response :success
    assert_select "p", text: /Democrats\s+are favored, winning 9,527 of 10,000 simulated elections/
  end

  test "show claims no simulations for an uncontested race, because none were run" do
    # Forecast::Simulator#certain_outcome awards the seat and draws no error
    # at all, so the page must not print a tally of worlds it never simulated.
    races(:senate_maine).update!(uncontested: true, uncontested_party: :dem)

    get race_path(races(:senate_maine).slug)

    assert_response :success
    assert_select "p", text: /only one candidate can win it, so the model awards the seat/
    assert_select "p", text: /simulated elections/, count: 0
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
    assert_select "[data-testid='unpolled-empty-state']", text: /the state's partisan lean/
    assert_select "[data-testid='polls-scatter-chart']", count: 0
    assert_select "[data-testid='poll-table']", count: 0
  end

  test "show keeps the newest three dispatches as teasers and lists the rest by headline" do
    race = races(:senate_maine)
    5.times do |i|
      Dispatch.create!(race: race, kind: :movement_note, status: :published, headline: "Maine move #{i}",
        body_markdown: "Body #{i}.", model_run: model_runs(:model_run_one), published_at: Time.zone.parse("2026-10-0#{i + 1} 09:00"))
    end

    get race_path(race.slug)

    assert_select "[data-testid='dispatch-card']", count: 3
    assert_select "[data-testid='dispatch-card'] h3", text: "Maine move 4"
    # On the race's own page the card's race link would point back here.
    assert_select "[data-testid='dispatch-card'] a[href='#{race_path(race.slug)}']", count: 0
    assert_select "[data-testid='earlier-dispatches'] h3", text: /Earlier dispatches\s*·\s*3/
    assert_select "[data-testid='earlier-dispatch']", count: 3
    assert_select "[data-testid='earlier-dispatch'] a[href='#{dispatch_path(dispatches(:maine_poll_reaction))}']",
                  text: dispatches(:maine_poll_reaction).headline
  end

  # Methodology: a House district's prior is its 2024 result, not a state's
  # lean. The empty state once said "state lean" on every race.
  test "an unpolled House district names its own fundamentals" do
    get race_path(races(:house_ny_17).slug)

    assert_response :success
    assert_select "[data-testid='unpolled-empty-state']", text: /the district's 2024 result and the national environment/
    assert_select "[data-testid='unpolled-empty-state']", text: /state/, count: 0
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

  test "polling table offers named matchup groups including missing and empty keys" do
    race = races(:senate_maine)
    race.polls.destroy_all
    keys = [ "dem:ellis|rep:rivers", "dem:jones|rep:rivers", nil, "" ]
    polls = keys.map.with_index do |key, index|
      create_poll(pollster: pollsters(:beacon_polling), race: race,
        field_end: Date.current - index, results: { dem: 51.0, rep: 45.0 }, matchup_key: key)
    end

    get race_path(race.slug)

    assert_response :success
    assert_select "label[for='poll-matchup']", text: "Candidate matchup"
    assert_select "select#poll-matchup[aria-describedby='poll-matchup-help'][aria-controls='race-poll-table']" do
      assert_select "option[value='']", text: "All matchups", count: 1
      polls.each_with_index do |poll, index|
        assert_select "option[value='#{index}']", text: "#{poll.matchup_heading} · 1 poll"
      end
    end
    assert_select "#poll-matchup-help", text: /Filters this polling table only.*Forecast values and scatter-chart data remain unchanged/m
    assert_select "[data-matchup-filter-target='status']", text: /Showing 4 polls across all matchups/
    assert_select "#race-poll-table tbody[data-matchup-filter-target='group']", count: 4
    assert_select "#race-poll-table tbody[hidden]", count: 0
    assert_select "[data-testid='poll-matchup-heading']", count: 4
    assert_select "[data-testid='earlier-matchup-tag']", count: 1
    assert_select "[data-testid='poll-row']", count: 4
    polls.each do |poll|
      assert_select "a[data-testid='poll-source-link'][href='#{poll.source_url}']"
    end
  end

  test "single matchup and unpolled pages omit the matchup selector" do
    race = races(:senate_maine)
    get race_path(race.slug)
    assert_select "[data-testid='poll-row']", count: race.polls.count
    assert_select "select#poll-matchup", count: 0

    race.polls.destroy_all
    race.touch
    get race_path(race.slug)
    assert_select "[data-testid='unpolled-empty-state']"
    assert_select "select#poll-matchup", count: 0
    assert_select "[data-testid='poll-table']", count: 0
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

  # A group whose matchup no longer matches the race's current candidate set
  # (a poll taken before the field was set) gets a small tag on its heading;
  # a group that still matches the current candidates doesn't.
  test "show tags a stale matchup group and leaves the current one untagged" do
    race = races(:house_ny_17)
    create_poll(
      pollster: pollsters(:beacon_polling), race: race, field_end: Date.current, sample_size: 600,
      results: { dem: 51.0, rep: 45.0 }, matchup_key: "dem:nolan|rep:halloran",
      raw_payload: { "columns" => { "Casey Nolan (D)" => "51%", "Drew Halloran (R)" => "45%" } }
    )
    create_poll(
      pollster: pollsters(:cardinal_research), race: race, field_end: Date.current - 30, sample_size: 500,
      results: { dem: 44.0, rep: 48.0 }, matchup_key: "dem:jones|rep:halloran",
      raw_payload: { "columns" => { "Pat Jones (D)" => "44%", "Drew Halloran (R)" => "48%" } }
    )

    get race_path(race.slug)

    headings = css_select("[data-testid='poll-matchup-heading']")
    current = headings.find { |row| row["data-matchup"] == "dem:nolan|rep:halloran" }
    stale = headings.find { |row| row["data-matchup"] == "dem:jones|rep:halloran" }

    assert_empty current.css("[data-testid='earlier-matchup-tag']"), "current matchup should carry no tag"
    assert_equal 1, stale.css("[data-testid='earlier-matchup-tag']").size
    assert_match "Different candidate matchup", stale.text
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
    assert_select "[data-testid='dispatch-byline']", text: /Written by the newsroom · #{Regexp.escape(dispatches(:maine_poll_reaction).model_slug)}/
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

  # The same card partial heads both pages, and on the dashboard it links
  # here. Rendered here it would link to the page it is already on.
  test "neither chamber page's summary card links to itself" do
    { senate_path => "senate", house_path => "house" }.each do |path, chamber|
      get path
      assert_select "[data-testid='chamber-card-#{chamber}'] [data-testid='chamber-card-link']", { count: 0 }, "#{path} card links to itself"
      assert_select "[data-testid='chamber-card-#{chamber}'] [data-testid='chamber-card-cta']", { count: 0 }, "#{path} card links to itself"
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

  # A slow sort used to look like a dead click: the old table stayed put, and
  # each repeat click made Turbo abort the request and start it again.
  # table-filter#sort is what dims the table and holds that repeat click back,
  # and the status region is where a screen reader hears that the sort is on
  # its way, so both hooks have to be in the markup.
  test "every sort link marks the table as sorting, with a status region to announce it" do
    [ senate_path, house_path ].each do |path|
      get path
      css_select("thead a").each do |link|
        assert_equal "table-filter#sort", link["data-action"],
                     "#{path}: a sort link without the action gives no feedback while the next page loads"
      end
      assert_select "[data-controller='table-filter'] [role='status'][data-table-filter-target='status']", count: 1
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

  test "a race page renders both internals views of its forecast" do
    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='race-masthead'] [data-variant='excl_internals']", count: 1
    assert_select "[data-testid='race-masthead'] [data-variant='incl_internals']", count: 1
    assert_select "[data-testid='forecast-detail'] [data-variant='excl_internals']", count: 1
    assert_select "[data-testid='forecast-detail'] [data-variant='incl_internals']", count: 1
  end

  test "an internal poll is badged and the table carries the per-view note" do
    create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 7, 20),
                race: races(:senate_maine), partisan: :dem, entry_mode: :nyt,
                results: { dem: 52.0, rep: 41.0 })

    get race_path(races(:senate_maine).slug)

    assert_select "tr[data-internal-poll] [data-testid='sponsor-badge']", minimum: 1
    assert_select "[data-testid='internals-note'] [data-variant='excl_internals']", count: 1
    assert_select "[data-testid='internals-note'] [data-variant='incl_internals']", count: 1
  end

  test "the chamber tables carry both views of each forecast cell" do
    get senate_path

    assert_select "[data-testid='senate-race-row'] [data-testid='rating-word'] [data-variant='incl_internals']", minimum: 1
  end

  # --- maps -----------------------------------------------------------------

  test "senate shows the map once boundaries exist, and no map before" do
    get senate_path
    assert_select "[data-testid='map-senate']", count: 0

    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    get senate_path

    assert_select "[data-testid='map-senate'] a[data-key='ME'][href='#{race_path(races(:senate_maine).slug)}']"
    assert_select "[data-testid='map-senate'] script[type='application/json']", text: /Maine Senate/
    assert_select "[data-testid='map-senate'] [data-testid='map-legend']"
  end

  test "house draws each district inside its state's clip" do
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])

    get house_path

    assert_select "[data-testid='map-house'] [id='house-clip-NY']"
    assert_select "[data-testid='map-house'] g[clip-path='url(#house-clip-NY)'] a[data-key='NY-17']"
    assert_select "[data-testid='map-house'] use.map-outline"
  end

  test "a Senate race page shows a locator with its state outlined" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "VT", box: [ -73.4, 42.7, -71.5, 45.0 ])

    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='race-map'] [data-testid='map-senate-locator'] path.map-highlight"
    assert_select "[data-testid='map-senate-locator'] a", count: 0
  end

  test "a House race page shows its state's districts with its own outlined" do
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])
    create_boundary(state: "NY", district: 18, box: [ -74.9, 41.2, -74.2, 41.9 ])

    get race_path(races(:house_ny_17).slug)

    assert_select "[data-testid='race-map'] [data-testid='map-state-NY'] g[clip-path='url(#state-NY-clip)'] path.map-highlight"
    assert_select "[data-testid='map-state-NY'] a[data-key='NY-17']"
  end

  test "a race page without boundaries renders no map" do
    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='race-map']", count: 0
  end

  test "the senate map svg is hidden from screen readers" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    get senate_path

    assert_select "[data-testid='map-senate'] svg[aria-hidden='true']"
  end

  test "a Senate race locator svg keeps role img" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    get race_path(races(:senate_maine).slug)

    assert_select "[data-testid='map-senate-locator'] svg[role='img']"
  end
end
