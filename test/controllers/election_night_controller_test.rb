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
    end
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
