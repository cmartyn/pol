require "test_helper"

class ElectionNightControllerTest < ActionDispatch::IntegrationTest
  test "empty state never invents a probability" do
    with_night_snapshot(nil) do
      get "/election-night"
      assert_response :success
      assert_select "h1", "Election night"
      assert_select ".night-status strong", "Waiting for the first forecast"
      assert_select ".night-probability", text: "—", count: 2
      assert_select ".night-dial-hand", count: 0
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_equal "no-store", response.headers["CDN-Cache-Control"]
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
      assert_select "meta[name=robots][content='noindex, nofollow']", count: 1
      assert_select ".night-date", /Experimental preview/
      assert_select "a[href='/election-night']", count: 0
    end
  end

  test "preview is absent from public navigation and does not change homepage indexing" do
    get "/"
    assert_response :success
    assert_select "a[href='/election-night']", count: 0
    assert_nil response.headers["X-Robots-Tag"]
    assert_select "meta[name=robots][content*=noindex]", count: 0
  end

  test "shows own chamber probabilities and unresolved caucus outcomes separately" do
    with_night_snapshot(snapshot) do
      get "/election-night"
      assert_response :success
      assert_select "[data-testid='night-house'] .night-probability", "64%"
      assert_select "[data-testid='night-senate'] .night-probability", "50%"
      assert_select "[data-testid='night-senate'] .night-republican", /30%/
      assert_select ".night-dial-hand", count: 2
      assert_select ".night-status strong", "Experimental live forecast"
      assert_select ".night-race-status", "Returns + prior"
      assert_select ".night-observed-votes > span", "12,345"
      assert_select ".night-method-body", /Independent historical turnout assumption/
    end
  end

  test "waiting for results labels probabilities as the pre-election starting point" do
    with_night_snapshot(snapshot.merge("status" => "awaiting_results")) do
      get "/election-night"
      assert_select ".night-status strong", "Awaiting usable returns"
      assert_select ".night-status p", /No usable returns/
    end
  end

  test "stale snapshots retain numbers but prominently disclose age" do
    with_night_snapshot(snapshot.merge("generated_at" => 15.minutes.ago.iso8601)) do
      get "/election-night"
      assert_select ".night-status--stale strong", "Updates delayed"
      assert_select "[data-testid='night-house'] .night-probability", "64%"
      get "/election-night/snapshot"
      assert_equal "stale", response.parsed_body.fetch("status")
    end
  end

  test "unusable source and invalid link are visible without leaking collector errors" do
    value = snapshot.deep_dup
    value["sources"] << {
      "id" => "unavailable", "label" => "County report", "url" => "javascript:alert(1)",
      "status" => "error", "error" => "private server path /tmp/credential"
    }
    with_night_snapshot(value) do
      get "/election-night"
      assert_select ".night-source-status--issue", "Unavailable"
      assert_select "a[href^='javascript:']", count: 0
      assert_select ".night-source-link", "County report"
      assert_not_includes response.body, "/tmp/credential"
      assert_select ".night-source-issue", /may be missing/
    end
  end

  test "snapshot revision is stable and changes when its input changes" do
    first_revision = nil
    with_night_snapshot(snapshot) do
      get "/election-night/snapshot"
      assert_response :success
      first_revision = response.parsed_body.fetch("revision")
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
      get "/election-night/snapshot"
      assert_equal first_revision, response.parsed_body.fetch("revision")
      assert_equal 0.64, response.parsed_body.dig("chambers", "house", "p_dem_control")
      assert_includes response.headers["Cache-Control"], "no-store"
    end
    with_night_snapshot(snapshot.merge("status" => "awaiting_results")) do
      get "/election-night/snapshot"
      assert_not_equal first_revision, response.parsed_body.fetch("revision")
    end
  end

  test "indirect evidence and uncontested seats are distinguished from direct returns" do
    value = snapshot.deep_dup
    value["races"] = [
      { "race_key" => "VA-01", "status" => "shared_update", "reason" => "Split-county district or missing county baseline; direct update withheld" },
      { "race_key" => "AL-01", "status" => "uncontested" }
    ]
    with_night_snapshot(value) do
      get "/election-night"
      assert_select ".night-race-status", "Related races + prior"
      assert_select ".night-race-reason", "Split-county district or missing county baseline; direct update withheld"
      assert_select ".night-race-status", "Uncontested"
      assert_select "[data-testid='internals-toggle']", count: 0
    end
  end

  test "missing or invalid chamber values leave the needle empty" do
    value = snapshot.deep_dup
    value["chambers"]["house"]["p_dem_control"] = nil
    value["chambers"]["senate"]["p_dem_control"] = 1.2
    with_night_snapshot(value) do
      get "/election-night"
      assert_select ".night-dial-hand", count: 0
      assert_select ".night-probability", text: "—", count: 2
    end
  end

  test "historical compilation is attributed separately from current official returns" do
    value = snapshot.deep_dup
    source = value.fetch("sources").first
    source.merge!(
      "label" => "Arizona Secretary of State",
      "url" => "https://azsos.gov/press",
      "baseline_url" => "https://example.org/2024-county-results.csv",
      "baseline_note" => "Public compilation of raw 2024 county counts; not official live data or another forecast.",
      "coverage_note" => "County-level reports only."
    )
    with_night_snapshot(value) do
      get "/election-night"
      assert_select ".night-source-heading a[href='https://azsos.gov/press']", "Arizona Secretary of State"
      assert_select ".night-source-baseline a[href='https://example.org/2024-county-results.csv']", "Vote counts"
      assert_select ".night-source-baseline", /Public compilation of raw 2024 county counts/
      assert_select ".night-source-note", "County-level reports only."
    end
  end

  test "source provenance is collapsed while upstream attribution remains visible" do
    value = snapshot.deep_dup
    value["sources"] += [
      { "id" => "civic_nc_01", "label" => "CivicAPI raw results — NC-01", "url" => "https://civicapi.org/api/v2/race/87299", "status" => "ok" },
      { "id" => "polling_desk", "label" => "Polling Desk raw totals, via CivicAPI", "url" => "https://polling-desk.com/results.csv", "status" => "ok" }
    ]
    with_night_snapshot(value) do
      get "/election-night"
      assert_select "#night-source-details[open]", count: 0
      assert_select "#night-source-details > summary", /Source status and provenance/
      assert_select "#night-source-details > summary span", "3 sources"
      assert_select "#night-source-details .night-source-list > li", count: 3
      assert_select ".night-sources > #night-source-attribution a[href='https://civicapi.org/']", "CivicAPI"
      assert_select ".night-sources > #night-source-attribution a[href='https://polling-desk.com/results']", "Polling Desk"
    end
    with_night_snapshot(snapshot) do
      get "/election-night"
      assert_select "#night-source-attribution", count: 0
    end
  end

  test "frozen historical data attribution is visible with its license and normalization note" do
    value = snapshot.deep_dup
    value["historical_baselines"] = { "upstream" => [
      { "publisher" => "Paul Heideman", "citation" => "https://doi.org/10.5281/zenodo.22976553", "license" => "CC BY 4.0" },
      { "publisher" => "Tony McGovern; raw Fox News results compilation", "url" => "https://github.com/tonmcg/US_County_Level_Election_Results_08-24" }
    ] }
    with_night_snapshot(value) do
      get "/election-night"
      assert_select ".night-sources > #night-historical-attribution", /which we normalized and validated/
      assert_select "#night-historical-attribution a[href='https://doi.org/10.5281/zenodo.22976553']", "Paul Heideman"
      assert_select "#night-historical-attribution a[href='https://creativecommons.org/licenses/by/4.0/']", "CC BY 4.0"
      assert_select "#night-historical-attribution a", "Tony McGovern"
      assert_select "#night-historical-attribution a[href^='https://docs.google.com/spreadsheets/']", "The Downballot"
    end
    value["historical_baselines"]["upstream"].first["citation"] = "javascript:alert(1)"
    with_night_snapshot(value) do
      get "/election-night"
      assert_select "#night-historical-attribution a[href^='javascript:']", count: 0
      assert_select "#night-historical-attribution", /Paul Heideman/
    end
    with_night_snapshot(snapshot) do
      get "/election-night"
      assert_select "#night-historical-attribution", count: 0
    end
  end

  test "source notes explain exclusions while baseline failures remain plain and safe" do
    value = snapshot.deep_dup
    value["sources"] = [ {
      "id" => "oh", "label" => "Ohio Secretary of State", "status" => "error",
      "coverage_note" => "Feed currently marked IsTest=true; unavailable until live results are published.",
      "baseline_url" => "javascript:alert(1)",
      "baseline_note" => "<script>alert('untrusted')</script>",
      "baseline_error" => "Private credential path /tmp/private-key"
    } ]
    with_night_snapshot(value) do
      get "/election-night"
      assert_select ".night-source-note", /IsTest=true/
      assert_select "[data-testid='night-baseline-unavailable']", /Historical comparison unavailable/
      assert_select ".night-source-baseline a[href^='javascript:']", count: 0
      assert_select ".night-source-baseline script", count: 0
      assert_not_includes response.body, "/tmp/private-key"
    end
  end

  test "an old date-only prior is disclosed independently of fresh model timestamps" do
    travel_to Time.utc(2026, 11, 3, 22) do
      with_night_snapshot(snapshot.merge("prior_as_of" => "2026-10-21")) do
        get "/election-night"
        assert_select ".night-status strong", "Experimental live forecast"
        assert_select "[data-testid='night-old-prior']", /more than 48 hours old/
      end
      with_night_snapshot(snapshot.merge("prior_as_of" => "2026-11-03")) do
        get "/election-night"
        assert_select "[data-testid='night-old-prior']", count: 0
      end
    end
  end

  test "prior age uses its timestamp offset and tolerates an unknown date" do
    travel_to Time.utc(2026, 11, 3, 22) do
      with_night_snapshot(snapshot.merge("prior_as_of" => "2026-11-01T16:59:00-05:00")) do
        get "/election-night"
        assert_select "[data-testid='night-old-prior']", count: 1
      end
      with_night_snapshot(snapshot.merge("prior_as_of" => "unknown")) do
        get "/election-night"
        assert_response :success
        assert_select "[data-testid='night-old-prior']", count: 0
        assert_select ".night-timestamp", /Pre-election prior frozen Not yet available/
      end
    end
  end

  test "connected competitive coverage is separate from partial coverage and model evidence" do
    value = snapshot.deep_dup
    value["coverage"].merge!(
      "races_with_raw_sources" => 400,
      "competitive_races_total" => 125,
      "competitive_races_with_raw_sources" => 10,
      "competitive_races_with_county_sources" => 3,
      "competitive_races_with_contest_sources" => 7,
      "competitive_races_with_partial_sources" => 2
    )
    with_night_snapshot(value) do
      get "/election-night"
      assert_select "[data-testid='night-competitive-coverage'] dt", "Competitive races with raw sources"
      assert_select "[data-testid='night-competitive-coverage'] dd", "10 / 125"
      assert_select "[data-testid='night-model-coverage'] dt", "Races directly using returns"
      assert_select "[data-testid='night-model-coverage'] dd", "1 / 470"
      assert_select "[data-testid='night-raw-breakdown']", "3 with county detail · 7 with contest totals · 2 with partial coverage only."
      assert_select ".night-coverage-note", /Partial coverage covers only some areas and is excluded/
      assert_select ".night-coverage-note", /direct model update also needs usable returns/
      assert_select ".night-method-body", /400 of 470 have whole-race raw sources/
    end
  end

  test "missing raw source is unknown while a connected zero and delayed partial total remain distinct" do
    value = snapshot.deep_dup
    value["races"] = [
      { "race_key" => "NC-01", "has_raw_source" => true, "raw_coverage_level" => "contest", "observed_votes" => 0, "status" => "prior_only" },
      { "race_key" => "VA-01", "has_raw_source" => false, "raw_coverage_level" => "none", "observed_votes" => 999, "status" => "shared_update" },
      { "race_key" => "NY-17", "has_raw_source" => true, "raw_coverage_level" => "partial", "raw_source_stale" => true, "observed_votes" => 1234, "status" => "prior_only" },
      { "race_key" => "NH-S", "has_raw_source" => true, "raw_coverage_level" => "county", "observed_votes" => 5678, "status" => "prior_only" }
    ]
    with_night_snapshot(value) do
      get "/election-night"
      assert_select "tr[data-race-key='NC-01'] .night-observed-votes > span", "0"
      assert_select "tr[data-race-key='NC-01'] .night-raw-level", "Contest total"
      assert_select "tr[data-race-key='VA-01'] .night-observed-votes > span", "—"
      assert_select "tr[data-race-key='VA-01'] .night-raw-level", "No raw source"
      assert_select "tr[data-race-key='NY-17'] .night-observed-votes > span", "1,234"
      assert_select "tr[data-race-key='NY-17'] .night-raw-level", "Partial coverage · delayed"
      assert_select "tr[data-race-key='NH-S'] .night-raw-level", "County detail"
      assert_select "tr[data-race-key='NH-S'] .night-race-status", "Prior only"
    end
  end

  test "remaining vote estimates show rounded model ranges and their historical basis" do
    value = snapshot.deep_dup
    value["coverage"].merge!("races_with_outstanding_estimates" => 420, "competitive_races_with_baselines" => 110, "competitive_races_total" => 125)
    value["races"].first["outstanding_votes"] = {
      "remaining_votes" => 123_456.7, "remaining_votes_low" => 100_001.2, "remaining_votes_high" => 155_599.2,
      "geography_scope" => "county", "turnout_basis" => "Matched 2022 county turnout"
    }
    value["races"] << { "race_key" => "ME-S", "outstanding_votes" => nil }
    with_night_snapshot(value) do
      get "/election-night"
      assert_select "th", "Estimated votes remaining"
      assert_select "tr[data-race-key='NC-01'] .night-outstanding-votes > span", "≈123,500"
      assert_select "tr[data-race-key='NC-01'] .night-outstanding-range", "Model range: 100,000–155,600"
      assert_select "tr[data-race-key='NC-01'] .night-outstanding-basis", "County estimate · Matched 2022 county turnout"
      assert_select "tr[data-race-key='ME-S'] .night-outstanding-votes > span", "—"
      assert_select "tr[data-race-key='ME-S'] .night-outstanding-range", count: 0
      assert_select "[data-testid='night-outstanding-coverage']", /420 races have remaining-vote estimates/
      assert_select "[data-testid='night-outstanding-coverage']", /110 of 125 competitive races have historical comparisons/
      assert_select "#night-outstanding-note", /historical turnout scenarios/
      assert_select "#night-outstanding-note", /do not establish that counting is complete/
    end
  end

  test "invalid remaining range is unknown and fallback raw sources are distinguished" do
    value = snapshot.deep_dup
    value["races"].first.merge!(
      "has_raw_source" => true, "raw_coverage_level" => "contest", "raw_source_fallback" => true, "raw_source_stale" => true,
      "outstanding_votes" => { "remaining_votes" => 200, "remaining_votes_low" => 300, "remaining_votes_high" => 400 }
    )
    with_night_snapshot(value) do
      get "/election-night"
      assert_select ".night-outstanding-votes > span", "—"
      assert_select ".night-outstanding-range", count: 0
      assert_select ".night-raw-level", "Contest total · fallback · delayed"
    end
    value["races"].first["outstanding_votes"] = {
      "remaining_votes" => 120, "remaining_votes_low" => 0, "remaining_votes_high" => 500,
      "geography_scope" => "contest", "turnout_basis" => "<script>bad()</script>"
    }
    with_night_snapshot(value) do
      get "/election-night"
      assert_select ".night-outstanding-votes > span", "≈120"
      assert_select ".night-outstanding-range", "Model range: 0–500"
      assert_select ".night-outstanding-basis script", count: 0
    end
  end

  private
    def with_night_snapshot(value, &block)
      store = Struct.new(:latest).new(value)
      stubbing(ElectionNight::Store, :new, store, &block)
    end

    def snapshot
      {
        "generated_at" => Time.current.iso8601, "prior_as_of" => "2026-11-03",
        "status" => "experimental",
        "chambers" => {
          "house" => { "p_dem_control" => 0.64, "p_rep_control" => 0.36, "mean_dem_seats" => 222.3 },
          "senate" => { "p_dem_control" => 0.50, "p_rep_control" => 0.30, "mean_dem_seats" => 50.6 }
        },
        "races" => [ { "race_key" => "NC-01", "p_dem_win" => 0.6, "p_rep_win" => 0.4, "status" => "returns", "observed_votes" => 12345 } ],
        "coverage" => { "races_with_returns" => 1, "races_total" => 470, "races_with_baselines" => 25 },
        "sources" => [ { "id" => "nc", "label" => "North Carolina", "url" => "https://er.ncsbe.gov", "status" => "ok", "fetched_at" => Time.current.iso8601, "published_at" => Time.current.iso8601 } ],
        "assumptions" => [ "Independent historical turnout assumption" ]
      }
    end
end
