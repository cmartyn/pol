require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "root renders the dashboard" do
    get root_path
    assert_response :success
    assert_select "h1", text: /2026 midterms forecast/
  end

  test "does not load PostHog in the test environment" do
    get root_path
    assert_select "script", text: /posthog\.init/, count: 0
  end

  test "does not require authentication" do
    get root_path
    assert_response :success
    assert_nil cookies[:session_id]
  end

  test "shows both chamber cards with the fixture world's forecast" do
    get root_path

    assert_select "[data-testid='chamber-card-senate']"
    assert_select "[data-testid='chamber-card-house']"
    assert_select "[data-testid='seat-histogram-senate']"
    assert_select "[data-testid='seat-histogram-house']"

    # Pre-toggle runs have no internals rows; both views use the published row.
    %w[excl_internals incl_internals].each do |variant|
      assert_select "[data-testid='chamber-card-senate'] [data-variant='#{variant}'] [aria-label='Democrats 55%']"
      assert_select "[data-testid='chamber-card-house'] [data-variant='#{variant}'] [aria-label='Democrats 48%']"
    end
  end

  # The chamber pages are the main thing a reader goes to from here, and the
  # card's only way in used to be its map — a link nothing on screen admitted
  # to. The headline and a footer line now say where they go. The histogram
  # stays outside both: it has its own pointer and arrow-key tooltip, which a
  # surrounding link would swallow.
  test "each dashboard card opens its chamber page from the headline and a footer link" do
    get root_path

    { "senate" => "Senate", "house" => "House" }.each do |chamber, title|
      assert_select "[data-testid='chamber-card-#{chamber}']" do
        assert_select "h2 a[data-testid='chamber-card-link'][href='/#{chamber}']", count: 1
        assert_select "a[data-testid='chamber-card-cta'][href='/#{chamber}']", text: /Full #{title} forecast/, count: 1
        assert_select "a [data-testid='seat-histogram-#{chamber}']", count: 0
      end
    end
  end

  # Right after the answer the reader came for, ahead of everything else the
  # dashboard says — not under the movers, where it sat two screens down.
  test "the subscribe box sits directly under the chamber cards" do
    get root_path

    body = response.body
    cards = body.index("data-testid=\"chamber-cards\"")
    form = body.index("id=\"subscription-form-homepage\"")
    environment = body.index("data-testid=\"national-environment\"")

    assert cards && form && environment
    assert_operator cards, :<, form
    assert_operator form, :<, environment
  end

  test "the header links to the footer's subscribe form on every page" do
    [ root_path, senate_path, methodology_path ].each do |path|
      get path
      assert_select "header a[href='#subscription-form-footer']", { text: "Subscribe", count: 1 }, "#{path} is missing the header link"
      assert_select "footer #subscription-form-footer", { count: 1 }, "#{path} is missing the link's target"
    end
  end

  test "loads both forecast variants together for each dashboard card and map" do
    run = model_runs(:model_run_one)
    %i[senate_chamber_forecast house_chamber_forecast].each do |fixture|
      chamber_forecasts(fixture).dup.update!(variant: :incl_internals, p_dem_control: 0.20, p_rep_control: 0.80)
    end
    %i[senate_maine senate_florida_special house_ny_17].each do |fixture|
      race = races(fixture)
      Forecast.find_or_initialize_by(model_run: run, race: race, variant: :excl_internals)
        .update!(p_dem_win: 0.60, p_rep_win: 0.40, mean_margin: 2.0)
      Forecast.create!(model_run: run, race: race, variant: :incl_internals,
                       p_dem_win: 0.20, p_rep_win: 0.80, mean_margin: -5.0)
    end
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "FL", box: [ -87.6, 24.5, -80.0, 31.0 ])
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])

    forecast_queries = /\ASELECT .* FROM "(?:chamber_forecasts|forecasts)"/
    with_fragment_caching do
      # Two cards and two maps each need one bulk query, regardless of how
      # many races or variants they render. No comparison run exists here.
      ActiveRecord::Base.connection.clear_query_cache
      assert_queries_match(forecast_queries, count: 4) { get root_path }

      assert_response :success
      { "senate" => 55, "house" => 48 }.each do |chamber, published_percent|
        assert_select "[data-testid='chamber-card-#{chamber}']" do
          assert_select "[data-variant='excl_internals'] [aria-label='Democrats #{published_percent}%']"
          assert_select "[data-variant='incl_internals'] [aria-label='Democrats 20%']"
        end
      end
      fills = "--fill-excl:#{Site::Maps::Palette.shade('dem', 0.60)};--fill-incl:#{Site::Maps::Palette.shade('rep', 0.80)}"
      %w[ME FL NY-17].each do |key|
        assert_select ".map-shape[data-key='#{key}'][style=?]", fills, count: 1
      end

      # Keep the reads inside the fragment so a hit does no forecast work.
      ActiveRecord::Base.connection.clear_query_cache
      assert_no_queries_match(forecast_queries) { get root_path }
      assert_response :success
    end
  end

  # The caveat has been reworded twice and the marker has outlived both: Phase
  # 3's "model likely overstates certainty", then a count of 538's components.
  # What has to survive every rewrite is that the House figure never appears
  # without saying it is a little too confident.
  #
  # Pinning the omission and the consequence rather than the sentence, because
  # the sentence is the part that keeps changing — and asserting the two
  # retired phrasings are gone, since the failure mode here is old copy
  # surviving a rewrite somewhere else on the page.
  test "the House control probability always carries its error-model note" do
    get root_path
    assert_select "[data-testid='chamber-card-house'] [data-testid='house-error-note']" do
      assert_select "*", text: /leaves out one correlated term/
      assert_select "*", text: /firmer than it should be/
    end
    refute_match(/overstates certainty/, response.body)
    # The dashboard must not imply this model is an unfinished copy of 538's.
    # That claim belongs on the methodology page, where it is sourced and
    # states a difference rather than a shortfall against a target.
    refute_match(/four of the five correlated error components/, response.body)
    # The Senate card needs no such note: the omitted component is a
    # district-level correlation and 35 races feel it far less than 435.
    assert_select "[data-testid='chamber-card-senate'] [data-testid='house-error-note']", count: 0
  end

  test "shows the national environment as a formatted margin" do
    get root_path
    assert_select "[data-testid='national-environment']"
  end

  # Regression guard for the bug where this surface built its Averager with
  # no house_effects lookup at all, publishing the unadjusted average while
  # every forecast displayed beside it was built from the adjusted one.
  test "the national environment is the house-effects-adjusted average, not the raw one" do
    HouseEffect.create!(model_run: model_runs(:model_run_one), pollster: pollsters(:delta_metrics),
                        effect_raw: 1.0, effect_shrunk: 1.0, residual_count: 5, applied: true)

    get root_path

    # Unadjusted, the fixture world's lone generic-ballot poll averages to
    # D+2.0 (see Newsroom::ContextTest) — the applied +1.0 effect must come
    # off it here exactly as it does everywhere else the average is printed.
    assert_select "[data-testid='national-environment']" do
      assert_select "*", text: "D+1.0"
    end
  end

  test "omits the Movers section when there's only one succeeded run" do
    get root_path
    assert_select "[data-testid='movers-section']", count: 0
  end

  test "shows the Movers section once there's a second succeeded run to compare against" do
    latest = model_runs(:model_run_one)
    previous = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: latest.started_at - 7.days)
    Forecast.create!(model_run: previous, race: races(:senate_maine), p_dem_win: 0.30, p_rep_win: 0.70, mean_margin: -10.0)

    get root_path

    assert_select "[data-testid='movers-section']"
    assert_select "[data-testid='mover-row']"
  end

  test "shows an honest empty state for dispatches when none are published" do
    Dispatch.delete_all
    get root_path
    assert_select "[data-testid='dispatches-empty']"
  end

  test "shows published dispatches, truncated, with a link to the full feed" do
    get root_path
    assert_select "[data-testid='dashboard-dispatches'] [data-testid='dispatch-card']"
    assert_select "a[href='#{dispatches_path}']"
  end

  test "renders a graceful empty dashboard when no model run has ever succeeded" do
    ModelRun.update_all(status: ModelRun.statuses.fetch("failed"))

    get root_path

    assert_response :success
    assert_select "[data-testid='dashboard-empty']"
    assert_select "[data-testid='chamber-card-senate']", count: 0
  end

  test "the corpus note shows while the feed corpus is fresh and not after" do
    get root_path
    assert_select "[data-testid='corpus-note']", count: 0

    Poll.first.update_columns(entry_mode: Poll.entry_modes.fetch("nyt"), created_at: 2.days.ago)

    get root_path
    assert_select "[data-testid='corpus-note']", count: 1
    assert_select "[data-testid='corpus-note'] a[href=?]", methodology_path(anchor: "data-sources")

    Poll.nyt.update_all(created_at: 8.days.ago)

    get root_path
    assert_select "[data-testid='corpus-note']", count: 0
  end

  test "the internals toggle and both variants of every number are in the page" do
    get root_path

    assert_select "[data-testid='internals-toggle']", count: 1
    # Chamber cards and the national environment each carry both views; the
    # CSS (keyed on html[data-internals]) shows one.
    assert_select "[data-testid='chamber-card-senate'] [data-variant='excl_internals']"
    assert_select "[data-testid='chamber-card-senate'] [data-variant='incl_internals']"
    assert_select "[data-testid='national-environment'] [data-variant='excl_internals']", count: 1
    assert_select "[data-testid='national-environment'] [data-variant='incl_internals']", count: 1
  end

  test "the dashboard's chamber cards carry small maps once boundaries exist, and /senate's card does not" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])

    get root_path
    assert_select "[data-testid='chamber-card-map-link'][href='/senate'] [data-testid='map-dashboard-senate']"
    assert_select "[data-testid='chamber-card-map-link'][href='/house'] [data-testid='map-dashboard-house']"
    assert_select "[data-testid='chamber-card-map'] a[data-key]", count: 0
    assert_select "[data-testid='chamber-card-map'] script[type='application/json']", count: 0

    get senate_path
    assert_select "[data-testid='chamber-card-map']", count: 0
  end
end
