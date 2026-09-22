# District and State Maps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a national Senate map, a national House district map, a Senate race locator, a House race state map, and small dashboard maps. All are drawn at render time from Census boundaries stored in Postgres; nothing geographic is committed.

**Architecture:**
- `pol:seed_boundaries` (`Ingest::BoundarySync` over a new `Ingest::TigerwebClient`) fetches shoreline-clipped state outlines and the 2026 congressional districts from the Census Bureau's TIGERweb API into a `boundaries` table.
- Pure-Ruby `Site::Maps` modules project (a d3-geo port), fit, simplify, and color them into one payload shape.
- One ERB partial renders that payload as inline SVG inside the existing fragment caches.
- A thin Stimulus controller adds hover and keyboard readouts through the existing `charts/tooltip.js`.

**Tech Stack:** Rails 8.1, Ruby 4.0.2, Postgres (jsonb), Stimulus, importmap, Tailwind v4, Minitest + WebMock + Capybara/Selenium.

**Spec:** `docs/superpowers/specs/2026-09-22-district-maps-design.md`. Read it first.

## Global Constraints

- **No geographic data in git**, including test fixtures. No `.geojson`, `.json` geometry, `.svg`, or `.topojson` files anywhere. Test geometry is made-up rectangles built in Ruby (`TigerwebStubHelper`, `BoundaryFactory`).
- **No new dependencies.** No gems, no importmap pins, no Node.
- **Tests never touch the network.** WebMock is already `disable_net_connect!`.
- **Double quotes** everywhere practical. Rubocop omakase style: spaces inside array brackets (`[ 1, 2 ]`).
- **Reuse existing nouns:** race, state, district, forecast, variant (`excl_internals` / `incl_internals`), model run. The new nouns are *boundary* (a row) and *outline* (a state's boundary, `district` nil).
- **The payload carries the words; the JS carries the geometry.** Every human-readable string is built in Ruby. The JavaScript only places strings, via `charts/tooltip.js` (textContent only).
- **Party colors:** `Site::Maps::Palette::PARTY` must equal `PARTY` in `app/javascript/charts/theme.js` (`#1d4ed8`, `#b91c1c`, `#64748b`).
- **Comments** state constraints the code can't show. Match the surrounding files' density (these files explain *why* at the top of each class). Never narrate the change.
- **Commits:** one per task, message as a plain sentence ending in a period, like `git log --oneline` shows (e.g. "Store Census boundaries for the maps."). Stage explicit paths only; never `git add -A`. The untracked `.agents/` directory is not ours.
- **Test commands:** `bin/rails test <paths>` (focused), `bin/rails test` (unit + integration), `bin/rails test:system` (browser), `bin/rubocop`, `bin/brakeman --no-pager`, and `bin/ci` for everything.

## Execution protocol (orchestrator)

| Wave | Task | Who | Where |
|---|---|---|---|
| 0 | Task 0 | orchestrator | `district-maps` branch in the main checkout |
| 1 | Tasks 1 and 2 in parallel | two Grok 4.7 agents | separate git worktrees off `district-maps` |
| 2 | Task 3 | Grok 4.7 | main checkout, after merging wave 1 |
| 3 | Task 4 | Grok 4.7 | main checkout |
| 4 | Task 5 | Grok 4.7 | main checkout |
| 5 | Task 6 | orchestrator | main checkout |

**Worktree agents (wave 1) must:**
1. Before anything else, run:
   ```bash
   cp /Users/chase/sites/pol/config/master.key config/master.key
   export POL_TEST_DATABASE=pol_test_<task>
   bin/rails db:test:prepare
   ```
   `<task>` is `boundaries` for Task 1 and `geometry` for Task 2. The master key is gitignored and needed to boot.
2. Use that exported variable for every test command.

Between waves, the orchestrator reviews the diff against this plan and the spec, runs `bin/ci`, and merges.

---

### Task 0: Branch, isolated test databases, docs (orchestrator)

**Files:**
- Modify: `config/database.yml` (the `test:` block)
- Add: `docs/superpowers/specs/2026-09-22-district-maps-design.md`, `docs/superpowers/plans/2026-09-22-district-maps.md`

- [ ] **Step 1: Branch**

```bash
git checkout -b district-maps
```

- [ ] **Step 2: Let an environment variable name the test database**

In `config/database.yml`, replace the test block's `database: pol_test` with:

```yaml
test:
  <<: *default
  # POL_TEST_DATABASE lets two checkouts (git worktrees) run the suite at
  # once without sharing a database; parallel workers still append -N.
  database: <%= ENV.fetch("POL_TEST_DATABASE", "pol_test") %>
```

- [ ] **Step 3: Verify the default is unchanged**

Run: `bin/rails test test/lib/site/format_test.rb`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add config/database.yml docs/superpowers/specs/2026-09-22-district-maps-design.md docs/superpowers/plans/2026-09-22-district-maps.md
git commit -m "Spec and plan the district maps; let POL_TEST_DATABASE name the test database."
```

---

### Task 1: Census boundaries in Postgres (wave 1, Grok agent A, worktree)

**Files:**
- Create: `db/migrate/20260922000001_create_boundaries.rb`
- Create: `app/models/boundary.rb`
- Create: `app/lib/ingest/tigerweb_client.rb`
- Create: `app/lib/ingest/boundary_sync.rb`
- Create: `test/test_helpers/tigerweb_stub_helper.rb`
- Create: `test/test_helpers/boundary_factory.rb`
- Modify: `test/test_helper.rb` (require and include the two helpers)
- Modify: `lib/tasks/pol.rake` (add `seed_boundaries` after `seed_races`)
- Modify: `README.md` (rake table), `docs/DEPLOY.md` (first-boot step 2, new "Maps" section)
- Test: `test/models/boundary_test.rb`, `test/lib/ingest/tigerweb_client_test.rb`, `test/lib/ingest/boundary_sync_test.rb`

**Interfaces:**
- Consumes:
  - `Race::STATE_NAMES` (50 states + DC)
  - `Ingest::SeedRaces::HOUSE_DISTRICTS` (435)
  - `Ingest::HouseCandidatesParser::AT_LARGE_DISTRICT` (1)
  - `Ingest::Sources.cycle` (2026)
  - `Pol::Params.fetch!(:scrape, :user_agent_contact)`
- Produces:
  - `Boundary` with `state`, `district` (nil for an outline), `geometry` (GeoJSON Hash), `source_url`, `#rings` (Array of rings, each an Array of `[lon, lat]`), and scopes `Boundary.outlines` and `Boundary.districts`.
  - `create_boundary(state:, district: nil, box: [ west, south, east, north ])` → `Boundary`, available in every test.
  - `tigerweb_rectangle(west, south, east, north)` → a GeoJSON Polygon Hash, available in every test.
  - `stub_tigerweb(states_hash)`.
  - `Ingest::BoundarySync.congress_for(cycle)` → Integer.

- [ ] **Step 1: Migration and model**

`db/migrate/20260922000001_create_boundaries.rb`:

```ruby
class CreateBoundaries < ActiveRecord::Migration[8.1]
  def change
    create_table :boundaries do |t|
      t.string :state, null: false
      t.integer :district
      t.jsonb :geometry, null: false
      t.string :source_url, null: false
      t.timestamps
    end

    # One outline per state, one row per district. Two partial indexes
    # rather than NULLS NOT DISTINCT so the pair works on any Postgres.
    add_index :boundaries, :state, unique: true, where: "district IS NULL", name: "index_boundaries_on_state_outline"
    add_index :boundaries, [ :state, :district ], unique: true, where: "district IS NOT NULL", name: "index_boundaries_on_state_and_district"
  end
end
```

`app/models/boundary.rb`:

```ruby
# A state's shoreline-clipped outline (district nil) or one congressional
# district, as simplified lon/lat GeoJSON fetched from the Census Bureau by
# Ingest::BoundarySync. Keyed like races — state + district — so a map joins
# the two without a lookup table. Longitudes are stored continuous across the
# date line (see BoundarySync.normalize), so nothing downstream special-cases
# the Aleutians.
class Boundary < ApplicationRecord
  validates :state, presence: true, format: { with: /\A[A-Z]{2}\z/, message: "must be a 2-letter code" }
  validates :geometry, :source_url, presence: true
  validates :district, uniqueness: { scope: :state }

  scope :outlines, -> { where(district: nil) }
  scope :districts, -> { where.not(district: nil) }

  # Every ring — exterior and hole alike — as [lon, lat] pairs. Maps draw
  # them with fill-rule evenodd, so which ring is a hole never matters here.
  def rings
    case geometry["type"]
    when "Polygon" then geometry["coordinates"]
    when "MultiPolygon" then geometry["coordinates"].flatten(1)
    else []
    end
  end
end
```

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `db/schema.rb` gains `create_table "boundaries"` with both indexes.

- [ ] **Step 2: Test helpers**

`test/test_helpers/boundary_factory.rb`:

```ruby
# Rectangle boundaries for map tests. Made-up geometry, never a real shape:
# no boundary data lives in this repository, fixtures included.
module BoundaryFactory
  def create_boundary(state:, box:, district: nil)
    west, south, east, north = box
    Boundary.create!(
      state: state,
      district: district,
      source_url: "https://example.com/tigerweb-fixture",
      geometry: { "type" => "Polygon", "coordinates" => [ [ [ west, south ], [ east, south ], [ east, north ], [ west, north ], [ west, south ] ] ] }
    )
  end
end
```

`test/test_helpers/tigerweb_stub_helper.rb`:

```ruby
# TIGERweb responses built from made-up rectangles, so Ingest::BoundarySync
# runs against the API's real response shapes without a real boundary in the
# repository. Each state is a box; its districts are equal vertical strips of
# that box, one per district code.
#
#   stub_tigerweb(
#     "DE" => { fips: "10", box: [ -75.8, 38.4, -75.0, 39.8 ], districts: %w[00] },
#     "RI" => { fips: "44", box: [ -71.9, 41.1, -71.1, 42.0 ], districts: %w[01 02] }
#   )
module TigerwebStubHelper
  STATE_LAYER_ID = 7
  DISTRICT_LAYER_ID = 0

  def stub_tigerweb(states, district_layer: "120th Congressional Districts", district_field: "CD120")
    state_url = Ingest::TigerwebClient.service_url(Ingest::BoundarySync::STATE_SERVICE)
    district_url = Ingest::TigerwebClient.service_url(Ingest::BoundarySync::DISTRICT_SERVICE)

    stub_request(:get, "#{state_url}?f=json").to_return(tigerweb_json(
      "layers" => [ { "id" => 3, "name" => "States 5M" }, { "id" => STATE_LAYER_ID, "name" => Ingest::BoundarySync::STATE_LAYER } ]
    ))
    stub_request(:get, "#{district_url}?f=json").to_return(tigerweb_json(
      "layers" => [ { "id" => 4, "name" => "119th Congressional Districts" }, { "id" => DISTRICT_LAYER_ID, "name" => district_layer } ]
    ))

    state_query = %r{\A#{Regexp.escape(state_url)}/#{STATE_LAYER_ID}/query}
    district_query = %r{\A#{Regexp.escape(district_url)}/#{DISTRICT_LAYER_ID}/query}

    stub_request(:get, state_query).with(query: hash_including("where" => "1=1"))
      .to_return(tigerweb_json(tigerweb_collection(states.map { |postal, spec| tigerweb_state(postal, spec) })))

    states.each do |postal, spec|
      where = { "where" => "STATE='#{spec.fetch(:fips)}'" }
      stub_request(:get, state_query).with(query: hash_including(where))
        .to_return(tigerweb_json(tigerweb_collection([ tigerweb_state(postal, spec) ])))
      stub_request(:get, district_query).with(query: hash_including(where))
        .to_return(tigerweb_json(tigerweb_collection(tigerweb_districts(spec, district_field))))
    end
  end

  def tigerweb_rectangle(west, south, east, north)
    { "type" => "Polygon", "coordinates" => [ [ [ west, south ], [ east, south ], [ east, north ], [ west, north ], [ west, south ] ] ] }
  end

  private
    def tigerweb_state(postal, spec)
      { "type" => "Feature", "properties" => { "STATE" => spec.fetch(:fips), "STUSAB" => postal }, "geometry" => tigerweb_rectangle(*spec.fetch(:box)) }
    end

    def tigerweb_districts(spec, field)
      west, south, east, north = spec.fetch(:box)
      codes = spec.fetch(:districts)
      step = (east - west) / codes.size
      codes.each_with_index.map do |code, index|
        {
          "type" => "Feature",
          "properties" => { "STATE" => spec.fetch(:fips), field => code },
          "geometry" => tigerweb_rectangle(west + (step * index), south, west + (step * (index + 1)), north)
        }
      end
    end

    def tigerweb_collection(features)
      { "type" => "FeatureCollection", "features" => features }
    end

    def tigerweb_json(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end
end
```

In `test/test_helper.rb`, add `require_relative "test_helpers/tigerweb_stub_helper"` and `require_relative "test_helpers/boundary_factory"` beside the other `require_relative` lines. Add `include TigerwebStubHelper` and `include BoundaryFactory` beside the other `include` lines.

- [ ] **Step 3: Write the failing model test**

`test/models/boundary_test.rb`:

```ruby
require "test_helper"

class BoundaryTest < ActiveSupport::TestCase
  test "rings passes a Polygon through and flattens a MultiPolygon" do
    assert_equal 1, Boundary.new(geometry: tigerweb_rectangle(-1, -1, 1, 1)).rings.size

    multi = Boundary.new(geometry: {
      "type" => "MultiPolygon",
      "coordinates" => [ tigerweb_rectangle(0, 0, 1, 1)["coordinates"], tigerweb_rectangle(2, 2, 3, 3)["coordinates"] ]
    })
    assert_equal 2, multi.rings.size
    assert_equal [ 2, 2 ], multi.rings.last.first
  end

  test "one outline per state and one row per district" do
    create_boundary(state: "RI", box: [ -71.9, 41.1, -71.1, 42.0 ])
    create_boundary(state: "RI", district: 1, box: [ -71.9, 41.1, -71.5, 42.0 ])

    assert_not Boundary.new(state: "RI", geometry: tigerweb_rectangle(0, 0, 1, 1), source_url: "https://example.com").valid?
    assert_not Boundary.new(state: "RI", district: 1, geometry: tigerweb_rectangle(0, 0, 1, 1), source_url: "https://example.com").valid?
    assert_equal [ "RI" ], Boundary.outlines.pluck(:state)
    assert_equal [ 1 ], Boundary.districts.pluck(:district)
  end

  test "state must be a two-letter code" do
    assert_not Boundary.new(state: "Rhode Island", geometry: tigerweb_rectangle(0, 0, 1, 1), source_url: "https://example.com").valid?
  end
end
```

Run: `bin/rails test test/models/boundary_test.rb`
Expected: PASS (the model already exists; this pins its contract).

- [ ] **Step 4: Write the failing client test**

`test/lib/ingest/tigerweb_client_test.rb`:

```ruby
require "test_helper"

class Ingest::TigerwebClientTest < ActiveSupport::TestCase
  SERVICE = "TIGERweb/Legislative".freeze
  SERVICE_URL = Ingest::TigerwebClient.service_url(SERVICE)

  setup do
    @client = Ingest::TigerwebClient.new
  end

  def layers(*pairs)
    { status: 200, body: { layers: pairs.map { |id, name| { id: id, name: name } } }.to_json }
  end

  test "finds a layer id by name, because TIGERweb renumbers layers between releases" do
    stub_request(:get, "#{SERVICE_URL}?f=json").to_return(layers([ 4, "119th Congressional Districts" ], [ 0, "120th Congressional Districts" ]))

    assert_equal 0, @client.layer_id(SERVICE, "120th Congressional Districts")
  end

  test "a missing layer name raises LayerNotFound" do
    stub_request(:get, "#{SERVICE_URL}?f=json").to_return(layers([ 0, "120th Congressional Districts" ]))

    assert_raises(Ingest::TigerwebClient::LayerNotFound) { @client.layer_id(SERVICE, "121st Congressional Districts") }
  end

  test "features returns the exact query url and the GeoJSON features" do
    stub = stub_request(:get, %r{\A#{Regexp.escape(SERVICE_URL)}/0/query})
      .with(query: hash_including("where" => "STATE='44'", "outFields" => "STATE,CD120", "outSR" => "4326",
                                  "f" => "geojson", "maxAllowableOffset" => "0.000400"))
      .to_return(status: 200, body: { type: "FeatureCollection", features: [
        { type: "Feature", properties: { "CD120" => "01" }, geometry: tigerweb_rectangle(0, 0, 1, 1) }
      ] }.to_json)

    url, features = @client.features(SERVICE, 0, where: "STATE='44'", out_fields: %w[STATE CD120], max_allowable_offset: 0.0004)

    assert_requested stub
    assert url.start_with?("#{SERVICE_URL}/0/query?")
    assert_equal "01", features.sole.dig("properties", "CD120")
  end

  test "an ArcGIS error object inside a 200 raises FetchFailed with its message" do
    stub_request(:get, %r{/query}).to_return(status: 200, body: { error: { code: 400, message: "Invalid query" } }.to_json)

    error = assert_raises(Ingest::TigerwebClient::FetchFailed) do
      @client.features(SERVICE, 0, where: "nonsense", out_fields: [], max_allowable_offset: 0.1)
    end
    assert_includes error.message, "Invalid query"
  end

  test "a truncated result raises rather than returning part of a state" do
    stub_request(:get, %r{/query}).to_return(status: 200, body: { type: "FeatureCollection", features: [], properties: { exceededTransferLimit: true } }.to_json)

    assert_raises(Ingest::TigerwebClient::FetchFailed) do
      @client.features(SERVICE, 0, where: "1=1", out_fields: [], max_allowable_offset: 0.1)
    end
  end

  test "retries a server error, then succeeds" do
    stub_request(:get, "#{SERVICE_URL}?f=json").to_return({ status: 503, body: "" }, layers([ 7, "States 500K" ]))

    assert_equal 7, @client.layer_id(SERVICE, "States 500K")
  end

  test "gives up after the last attempt" do
    stub_request(:get, "#{SERVICE_URL}?f=json").to_return(status: 503, body: "")

    assert_raises(Ingest::TigerwebClient::FetchFailed) { @client.layer_id(SERVICE, "States 500K") }
    assert_requested :get, "#{SERVICE_URL}?f=json", times: Ingest::TigerwebClient::ATTEMPTS
  end

  test "identifies itself with the contact address" do
    stub = stub_request(:get, "#{SERVICE_URL}?f=json").with(headers: { "User-Agent" => /contact: / }).to_return(layers([ 0, "x" ]))

    @client.layer_id(SERVICE, "x")

    assert_requested stub
  end
end
```

Run: `bin/rails test test/lib/ingest/tigerweb_client_test.rb`
Expected: FAIL with `uninitialized constant Ingest::TigerwebClient`.

- [ ] **Step 5: Implement the client**

`app/lib/ingest/tigerweb_client.rb`:

```ruby
require "net/http"
require "uri"
require "json"

module Ingest
  # Reads the Census Bureau's TIGERweb ArcGIS REST API, politely: one request
  # per MIN_INTERVAL seconds, the same descriptive User-Agent as
  # WikipediaClient, and bounded retries on transport and server errors.
  #
  #   client = Ingest::TigerwebClient.new
  #   layer = client.layer_id("TIGERweb/Legislative", "120th Congressional Districts")
  #   url, features = client.features("TIGERweb/Legislative", layer,
  #     where: "STATE='44'", out_fields: %w[STATE CD120], max_allowable_offset: 0.0004)
  class TigerwebClient
    Error = Class.new(StandardError)
    FetchFailed = Class.new(Error)
    # TIGERweb renumbers layers between releases, so layers are found by
    # name. A name that isn't there means the service changed shape, or the
    # cycle moved to a Congress it hasn't published yet — nothing should
    # guess at a replacement.
    LayerNotFound = Class.new(Error)

    BASE = "https://tigerweb.geo.census.gov/arcgis/rest/services/".freeze

    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 60
    ATTEMPTS = 3
    MIN_INTERVAL = 1.0
    BACKOFF_BASE = 0.5

    RETRIABLE_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH, EOFError, SocketError
    ].freeze

    def self.service_url(service)
      "#{BASE}#{service}/MapServer"
    end

    # Pacing and backoff default to zero under test for the same reason as
    # WikipediaClient's: WebMock answers instantly and there is no server to
    # be kind to.
    def initialize(min_interval: nil, backoff_base: nil, sleeper: nil)
      @min_interval = min_interval || (Rails.env.test? ? 0 : MIN_INTERVAL)
      @backoff_base = backoff_base || (Rails.env.test? ? 0 : BACKOFF_BASE)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @last_request_finished_at = nil
    end

    def layer_id(service, layer_name)
      json = get_json(URI("#{self.class.service_url(service)}?f=json"))
      layer = Array(json["layers"]).find { |candidate| candidate["name"] == layer_name }
      raise LayerNotFound, "#{service} has no layer named #{layer_name.inspect}" unless layer

      layer.fetch("id")
    end

    # [query_url, features]. The URL is what each stored row cites as its
    # source_url.
    def features(service, layer_id, where:, out_fields:, max_allowable_offset:)
      uri = query_uri(service, layer_id, where: where, out_fields: out_fields, max_allowable_offset: max_allowable_offset)
      json = get_json(uri)
      if json["exceededTransferLimit"] || json.dig("properties", "exceededTransferLimit")
        raise FetchFailed, "#{uri}: exceeded the transfer limit, so the result would be partial"
      end

      [ uri.to_s, Array(json["features"]) ]
    end

    private
      def query_uri(service, layer_id, where:, out_fields:, max_allowable_offset:)
        params = {
          where: where,
          outFields: out_fields.join(","),
          returnGeometry: "true",
          outSR: "4326",
          geometryPrecision: "5",
          maxAllowableOffset: format("%.6f", max_allowable_offset),
          f: "geojson"
        }
        URI("#{self.class.service_url(service)}/#{layer_id}/query?#{URI.encode_www_form(params)}")
      end

      def get_json(uri)
        ATTEMPTS.times do |index|
          attempt = index + 1
          begin
            throttle!
            response = perform(uri)
          rescue *RETRIABLE_ERRORS => e
            raise FetchFailed, "#{uri}: #{e.class}: #{e.message}" if attempt == ATTEMPTS

            back_off(attempt)
            next
          end

          if response.is_a?(Net::HTTPServerError)
            raise FetchFailed, "#{uri}: HTTP #{response.code}" if attempt == ATTEMPTS

            back_off(attempt)
            next
          end
          raise FetchFailed, "#{uri}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          return parse(uri, response.body)
        end
      end

      # ArcGIS reports a bad query as HTTP 200 carrying an error object.
      def parse(uri, body)
        json = JSON.parse(body.to_s)
        raise FetchFailed, "#{uri}: #{json.dig("error", "message") || json["error"]}" if json.is_a?(Hash) && json["error"]

        json
      rescue JSON::ParserError => e
        raise FetchFailed, "#{uri}: unparseable response (#{e.message})"
      end

      def perform(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        begin
          http.request(Net::HTTP::Get.new(uri, "User-Agent" => user_agent, "Accept" => "application/json"))
        ensure
          @last_request_finished_at = monotonic_now
          http.finish if http.started?
        end
      end

      def back_off(attempt)
        @sleeper.call(@backoff_base * (2**(attempt - 1)))
      end

      def throttle!
        return if @min_interval <= 0 || @last_request_finished_at.nil?

        elapsed = monotonic_now - @last_request_finished_at
        @sleeper.call(@min_interval - elapsed) if elapsed < @min_interval
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def user_agent
        "pol/0.1 (2026 midterms forecast site; contact: #{Pol::Params.fetch!(:scrape, :user_agent_contact)})"
      end
  end
end
```

Run: `bin/rails test test/lib/ingest/tigerweb_client_test.rb`
Expected: PASS

- [ ] **Step 6: Write the failing sync test**

`test/lib/ingest/boundary_sync_test.rb`:

```ruby
require "test_helper"

class Ingest::BoundarySyncTest < ActiveSupport::TestCase
  # PR is in the survey response but not in `states:`, so it must be ignored.
  # "ZZ" (water-only) and "98" (delegate) are not districts.
  WORLD = {
    "DE" => { fips: "10", box: [ -75.8, 38.4, -75.0, 39.8 ], districts: %w[00] },
    "RI" => { fips: "44", box: [ -71.9, 41.1, -71.1, 42.0 ], districts: %w[01 02 ZZ] },
    "PR" => { fips: "72", box: [ -67.3, 17.9, -65.2, 18.5 ], districts: %w[98] }
  }.freeze

  setup do
    seed_house_races("DE" => 1, "RI" => 2)
  end

  def seed_house_races(counts)
    counts.each do |state, count|
      (1..count).each do |district|
        Race.create!(office: :house, state: state, district: district, cycle: 2026,
                     slug: "house-#{state.downcase}-#{district}-boundary-sync-test", baseline_margin: 0.0)
      end
    end
  end

  def sync(states: %w[DE RI], expected_districts: 3, cycle: 2026)
    Ingest::BoundarySync.new(cycle: cycle, states: states, expected_districts: expected_districts).call
  end

  test "stores one outline per state and every voting district, at-large as district 1" do
    stub_tigerweb(WORLD)

    summary = sync

    assert_equal 2, summary.outlines
    assert_equal 3, summary.districts
    assert_operator summary.points, :>, 0
    assert_equal %w[DE RI], Boundary.outlines.order(:state).pluck(:state)
    assert_equal [ [ "DE", 1 ], [ "RI", 1 ], [ "RI", 2 ] ], Boundary.districts.order(:state, :district).pluck(:state, :district)
    assert Boundary.all.all? { |boundary| boundary.source_url.start_with?(Ingest::TigerwebClient::BASE) }
  end

  test "asks for each state at a detail level set by its own width" do
    stub_tigerweb(WORLD)

    sync

    # RI's box spans 0.8 degrees of longitude: 0.8 / 2000 = 0.0004.
    assert_requested(:get, %r{Legislative/MapServer/\d+/query}) do |request|
      request.uri.query_values["where"] == "STATE='44'" && request.uri.query_values["maxAllowableOffset"] == "0.000400"
    end
  end

  test "the district layer and field are named for the cycle's Congress" do
    assert_equal 120, Ingest::BoundarySync.congress_for(2026)
    assert_equal 121, Ingest::BoundarySync.congress_for(2028)

    stub_tigerweb(WORLD)
    assert_raises(Ingest::TigerwebClient::LayerNotFound) { sync(cycle: 2028) }
  end

  test "a state whose districts disagree with the race board raises and keeps the previous set" do
    create_boundary(state: "VT", box: [ -73.4, 42.7, -71.5, 45.0 ])
    stub_tigerweb(WORLD.merge("RI" => WORLD["RI"].merge(districts: %w[01])))

    error = assert_raises(Ingest::BoundarySync::IncompleteSource) { sync(expected_districts: 2) }

    assert_includes error.message, "RI 1 (races: 2)"
    assert_equal [ "VT" ], Boundary.pluck(:state)
  end

  test "the national total must match too" do
    stub_tigerweb(WORLD)

    assert_raises(Ingest::BoundarySync::IncompleteSource) { sync(expected_districts: 435) }
    assert_equal 0, Boundary.count
  end

  test "a state with no outline raises" do
    stub_tigerweb(WORLD.slice("DE"))

    error = assert_raises(Ingest::BoundarySync::IncompleteSource) { sync }
    assert_includes error.message, "RI"
  end

  test "longitudes west of the date line are stored continuous" do
    seed_house_races("AK" => 1)
    stub_tigerweb("AK" => { fips: "02", box: [ 172.0, 51.0, 179.0, 53.0 ], districts: %w[00] })

    sync(states: %w[AK], expected_districts: 1)

    longitudes = Boundary.outlines.sole.rings.flatten(1).map(&:first)
    assert longitudes.all?(&:negative?)
    assert_in_delta(-188.0, longitudes.min, 1e-9)
  end

  test "running twice replaces rather than duplicates" do
    stub_tigerweb(WORLD)

    sync
    sync

    assert_equal 5, Boundary.count
  end
end
```

Run: `bin/rails test test/lib/ingest/boundary_sync_test.rb`
Expected: FAIL with `uninitialized constant Ingest::BoundarySync`.

- [ ] **Step 7: Implement the sync**

`app/lib/ingest/boundary_sync.rb`:

```ruby
module Ingest
  # Fetches every boundary the site's maps draw — one shoreline-clipped
  # outline per state, and every congressional district on the lines in
  # effect for the cycle — from the Census Bureau's TIGERweb API, and replaces
  # the boundaries table with them in one transaction.
  #
  # Like SeedRaces it refuses to half-succeed: a missing outline, or any
  # district count that disagrees with the race board, raises
  # IncompleteSource before anything is written, and the previous set stays.
  #
  # Nothing about the source is written down that the source can tell us:
  # layers are found by name, the Congress number comes from the cycle, and
  # FIPS codes are mapped to postal codes by the state layer's own fields.
  class BoundarySync
    IncompleteSource = Class.new(StandardError)

    # Cartographic boundaries: generalized and clipped to the shoreline,
    # unlike the legal TIGER lines, which run out into the Great Lakes.
    STATE_SERVICE = "Generalized_ACS2025/State_County".freeze
    STATE_LAYER = "States 500K".freeze
    # Legal district lines, which do extend into water; the maps clip them to
    # the state outline when drawing.
    DISTRICT_SERVICE = "TIGERweb/Legislative".freeze

    # The survey pass only needs each state's codes and extent.
    SURVEY_OFFSET = 0.05
    # Per-state detail: longitude span / DETAIL_STEPS, so a small state is
    # fetched finer than a large one and both land near half a pixel on a
    # 600 px state map.
    DETAIL_STEPS = 2000.0

    AT_LARGE_CODE = "00".freeze
    DELEGATE_CODE = "98".freeze
    DISTRICT_CODE = /\A\d\d\z/
    FIPS_CODE = /\A\d\d\z/

    Summary = Struct.new(:outlines, :districts, :points, keyword_init: true)

    # The Congress elected in a cycle's November: 2026 elects the 120th.
    def self.congress_for(cycle)
      ((cycle - 1788) / 2) + 1
    end

    # "00" is an at-large seat, which this app numbers 1; "01".."53" are
    # themselves. Delegates ("98") and water-only pieces ("ZZ") have no race
    # and come back nil.
    def self.district_number(code)
      return HouseCandidatesParser::AT_LARGE_DISTRICT if code == AT_LARGE_CODE
      return nil unless code.to_s.match?(DISTRICT_CODE) && code != DELEGATE_CODE

      code.to_i
    end

    # No U.S. state reaches east of the prime meridian, so a positive
    # longitude is an Aleutian island west of 180° and becomes lon − 360.
    def self.normalize(geometry)
      { "type" => geometry.fetch("type"), "coordinates" => normalize_positions(geometry.fetch("coordinates")) }
    end

    def self.normalize_positions(node)
      if node.first.is_a?(Numeric)
        lon, lat = node
        [ (lon.positive? ? lon - 360 : lon).round(5), lat.round(5) ]
      else
        node.map { |child| normalize_positions(child) }
      end
    end

    def self.positions(geometry)
      geometry.fetch("coordinates").flatten.each_slice(2)
    end

    def initialize(client: TigerwebClient.new, logger: Rails.logger, cycle: Sources.cycle,
                   states: Race::STATE_NAMES.keys, expected_districts: SeedRaces::HOUSE_DISTRICTS)
      @client = client
      @logger = logger
      @congress = self.class.congress_for(cycle)
      @states = states
      @expected_districts = expected_districts
    end

    def call
      outline_layer = @client.layer_id(STATE_SERVICE, STATE_LAYER)
      district_layer = @client.layer_id(DISTRICT_SERVICE, district_layer_name)

      rows = survey(outline_layer).flat_map do |state, info|
        offset = info.fetch(:lon_span) / DETAIL_STEPS
        @logger.info("[boundaries] #{state}: detail #{format("%.5f", offset)}°")
        [ outline_row(outline_layer, state, info.fetch(:fips), offset) ] +
          district_rows(district_layer, state, info.fetch(:fips), offset)
      end

      check_counts!(rows)
      write!(rows)
    end

    private
      def district_layer_name
        "#{@congress.ordinalize} Congressional Districts"
      end

      def district_field
        "CD#{@congress}"
      end

      # { "RI" => { fips: "44", lon_span: 0.8 }, ... } for every expected state.
      def survey(layer)
        _url, features = @client.features(STATE_SERVICE, layer, where: "1=1", out_fields: %w[STATE STUSAB], max_allowable_offset: SURVEY_OFFSET)
        found = features.each_with_object({}) do |feature, index|
          postal = feature.dig("properties", "STUSAB")
          fips = feature.dig("properties", "STATE").to_s
          next unless @states.include?(postal) && feature["geometry"] && fips.match?(FIPS_CODE)

          longitudes = self.class.positions(self.class.normalize(feature["geometry"])).map(&:first)
          index[postal] = { fips: fips, lon_span: longitudes.max - longitudes.min }
        end

        missing = @states - found.keys
        raise IncompleteSource, "#{STATE_LAYER} has no outline for #{missing.sort.join(", ")}" if missing.any?

        found.sort.to_h
      end

      def outline_row(layer, state, fips, offset)
        url, features = @client.features(STATE_SERVICE, layer, where: "STATE='#{fips}'", out_fields: %w[STATE STUSAB], max_allowable_offset: offset)
        feature = features.find { |candidate| candidate["geometry"] }
        raise IncompleteSource, "#{STATE_LAYER} returned no outline for #{state}" unless feature

        { state: state, district: nil, geometry: self.class.normalize(feature["geometry"]), source_url: url }
      end

      def district_rows(layer, state, fips, offset)
        url, features = @client.features(DISTRICT_SERVICE, layer, where: "STATE='#{fips}'", out_fields: [ "STATE", district_field ], max_allowable_offset: offset)
        features.filter_map do |feature|
          number = self.class.district_number(feature.dig("properties", district_field))
          next unless number && feature["geometry"]

          { state: state, district: number, geometry: self.class.normalize(feature["geometry"]), source_url: url }
        end
      end

      def check_counts!(rows)
        districts = rows.select { |row| row[:district] }
        found = districts.group_by { |row| row[:state] }.transform_values(&:size)
        expected = Race.house.where(state: @states).group(:state).count
        mismatches = (found.keys | expected.keys).sort.filter_map do |state|
          got = found.fetch(state, 0)
          want = expected.fetch(state, 0)
          "#{state} #{got} (races: #{want})" unless got == want
        end

        problems = []
        problems << "expected #{@expected_districts} districts, got #{districts.size}" unless districts.size == @expected_districts
        problems << "duplicate districts" unless districts.map { |row| row.values_at(:state, :district) }.uniq.size == districts.size
        problems << "district counts disagree with the race board: #{mismatches.join(", ")}" if mismatches.any?
        raise IncompleteSource, "#{district_layer_name}: #{problems.join("; ")}" if problems.any?
      end

      def write!(rows)
        Boundary.transaction do
          Boundary.delete_all
          Boundary.insert_all!(rows)
        end

        Summary.new(
          outlines: rows.count { |row| row[:district].nil? },
          districts: rows.count { |row| row[:district] },
          points: rows.sum { |row| self.class.positions(row[:geometry]).count }
        )
      end
  end
end
```

Run: `bin/rails test test/lib/ingest/boundary_sync_test.rb test/lib/ingest/tigerweb_client_test.rb test/models/boundary_test.rb`
Expected: PASS

If `insert_all!` stores `geometry` as a JSON string rather than a jsonb object (`Boundary.first.geometry` is a String), switch to `rows.each { |row| Boundary.create!(row) }` inside the same transaction. Make that change only if the tests show it.

- [ ] **Step 8: Rake task and docs**

In `lib/tasks/pol.rake`, directly after the `seed_races` task:

```ruby
  desc "Fetch state outlines and the cycle's congressional district lines from the Census Bureau (TIGERweb) into boundaries"
  task seed_boundaries: :environment do
    summary = Ingest::BoundarySync.new.call

    puts
    puts "  Boundaries (#{Ingest::Sources.cycle})"
    puts "  " + "-" * 46
    printf("  %-28s %16d\n", "State outlines", summary.outlines)
    printf("  %-28s %16d\n", "Districts", summary.districts)
    printf("  %-28s %16d\n", "Points stored", summary.points)
    puts "  " + "-" * 46
    puts
  end
```

In `README.md`'s rake table, add a row after `pol:seed_races`:

```markdown
| `bin/rails pol:seed_boundaries` | Fetches every state's shoreline-clipped outline and every congressional district on the cycle's lines (the 120th Congress's for 2026, including the states that redrew mid-decade) from the Census Bureau's TIGERweb API into `boundaries`, which every map is drawn from. Needs `pol:seed_races` first: it refuses to write unless each state's district count matches its House races. About two minutes; re-run only when the Census corrects the lines. |
```

In `docs/DEPLOY.md`, change first-boot step 2's command to:

```
bin/kamal app exec 'bin/rails pol:seed_races pol:seed_boundaries pol:scrape pol:model'
```

Then add this section before "## Costs":

```markdown
## Maps

Every map is drawn at render time from the `boundaries` table, which
`bin/rails pol:seed_boundaries` fills from the Census Bureau's TIGERweb API
(shoreline-clipped state outlines, and the congressional district lines in
effect for the cycle). No boundary data is in the repository or the image.
Until it has run, pages render without maps. Run it once per environment:

    bin/kamal app exec 'bin/rails pol:seed_boundaries'

Re-run it only if the Census corrects the lines (a court-ordered redraw) or
for a new cycle, which moves the derived Congress number. If TIGERweb has not
yet published that Congress's layer, the task fails loudly and the existing
boundaries stay.
```

- [ ] **Step 9: Full suite, lint, commit**

Run: `bin/rails test && bin/rubocop && bin/brakeman --no-pager`
Expected: all pass, no offenses, no warnings.

```bash
git add db/migrate/20260922000001_create_boundaries.rb db/schema.rb app/models/boundary.rb \
  app/lib/ingest/tigerweb_client.rb app/lib/ingest/boundary_sync.rb lib/tasks/pol.rake \
  test/test_helper.rb test/test_helpers/tigerweb_stub_helper.rb test/test_helpers/boundary_factory.rb \
  test/models/boundary_test.rb test/lib/ingest/tigerweb_client_test.rb test/lib/ingest/boundary_sync_test.rb \
  README.md docs/DEPLOY.md
git commit -m "Store Census boundaries for the maps, fetched once by pol:seed_boundaries."
```

---

### Task 2: Projection, simplification, and the canvas (wave 1, Grok agent B, worktree)

**Files:**
- Create: `app/lib/site/maps/conic_equal_area.rb`
- Create: `app/lib/site/maps/projection.rb`
- Create: `app/lib/site/maps/path.rb`
- Create: `app/lib/site/maps/canvas.rb`
- Test: `test/lib/site/maps/conic_equal_area_test.rb`, `test/lib/site/maps/projection_test.rb`, `test/lib/site/maps/path_test.rb`, `test/lib/site/maps/canvas_test.rb`

**Interfaces:**
- Consumes: nothing from Task 1. A "boundary" here is any object with `#state` (a 2-letter String) and `#rings` (an Array of rings, each an Array of `[lon, lat]`). `Boundary` satisfies this, and the tests use a Struct.
- Produces:
  - `Site::Maps::ConicEqualArea.new(parallels:, rotate:, center: [ 0, 0 ], scale: 1.0, translate: [ 0, 0 ])`, with `#call(lon, lat)` → `[x, y]` and `#parallels`.
  - `Site::Maps::Projection.albers_usa(state)` → `ConicEqualArea`.
  - `Site::Maps::Projection.fitted(rings)` → `ConicEqualArea`.
  - `Site::Maps::Path.simplify(points, tolerance)`, `.encode(rings)` → String, `.number(tenths)` → String, `.centroid(rings)` → `[x, y]`, `.signed_area(ring)` → Float.
  - `Site::Maps::Canvas.national(outlines, width: 960, tolerance: 0.5, padding: 2)`.
  - `Site::Maps::Canvas.state(outline, width: 600, max_height: 480, tolerance: 0.5, padding: 4)`.
  - Canvas instances expose `#path(boundary)` → String (never empty for a boundary with rings), `#centroid(boundary)` → `[x, y]` rounded to 0.1, `#view_box` → `"0 0 W H"`, `#width`, `#height`.

The reference values below were computed with d3-geo 3.x outside the repo. The Ruby port was checked against them to 1e-9 before this plan was written.

- [ ] **Step 1: Write the failing projection tests**

`test/lib/site/maps/conic_equal_area_test.rb`:

```ruby
require "test_helper"

# Reference values from d3-geo 3.x (geoConicEqualArea), computed once outside
# the repository; the port must agree to 1e-9.
class Site::Maps::ConicEqualAreaTest < ActiveSupport::TestCase
  def assert_point(expected, actual)
    assert_in_delta expected[0], actual[0], 1e-9
    assert_in_delta expected[1], actual[1], 1e-9
  end

  test "a unit-scale conic matches d3" do
    projection = Site::Maps::ConicEqualArea.new(parallels: [ 40, 45 ], rotate: 72)

    assert_point [ 0.012111169299657693, -0.6931700789856656 ], projection.call(-71.06, 42.36)
    assert_point [ -0.019745469143738033, -0.6695216254861878 ], projection.call(-73.5, 41.0)
    assert_equal [ 40, 45 ], projection.parallels
  end

  test "parallels symmetric about the equator are refused" do
    assert_raises(ArgumentError) { Site::Maps::ConicEqualArea.new(parallels: [ -10, 10 ], rotate: 0) }
  end
end
```

`test/lib/site/maps/projection_test.rb`:

```ruby
require "test_helper"

# Reference values from d3-geo 3.x's geoAlbersUsa() at its defaults.
class Site::Maps::ProjectionTest < ActiveSupport::TestCase
  def assert_point(expected, actual)
    assert_in_delta expected[0], actual[0], 1e-9
    assert_in_delta expected[1], actual[1], 1e-9
  end

  test "albers_usa matches d3 for the lower 48" do
    assert_point [ 794.5954450548626, 176.53258338778596 ], Site::Maps::Projection.albers_usa("NY").call(-74.006, 40.7128)
    assert_point [ 159.14774137678137, 37.02484281589295 ], Site::Maps::Projection.albers_usa("WA").call(-122.33, 47.61)
    assert_point [ 755.9622778761034, 470.2325823020949 ], Site::Maps::Projection.albers_usa("FL").call(-80.19, 25.76)
  end

  test "Alaska and Hawaii land in d3's insets, including west of the date line" do
    alaska = Site::Maps::Projection.albers_usa("AK")

    assert_point [ 171.16312940682022, 446.9316317975319 ], alaska.call(-149.9, 61.22)
    assert_point [ 33.78981605127143, 470.4058896087959 ], alaska.call(173.2, 52.9)
    assert_point [ 33.78981605127143, 470.4058896087959 ], alaska.call(173.2 - 360, 52.9)
    assert_point [ 298.44898072875196, 450.9298708116952 ], Site::Maps::Projection.albers_usa("HI").call(-157.86, 21.31)
  end

  test "a fitted conic is centered on the state's middle longitude" do
    rings = [ [ [ -72.0, 41.0 ], [ -70.0, 41.0 ], [ -70.0, 47.0 ], [ -72.0, 47.0 ], [ -72.0, 41.0 ] ] ]
    projection = Site::Maps::Projection.fitted(rings)

    assert_equal [ 42.0, 46.0 ], projection.parallels
    assert_in_delta 0.0, projection.call(-71.0, 44.0).first, 1e-12
    assert_in_delta(-projection.call(-72.0, 44.0).first, projection.call(-70.0, 44.0).first, 1e-12)
  end
end
```

Run: `bin/rails test test/lib/site/maps/conic_equal_area_test.rb test/lib/site/maps/projection_test.rb`
Expected: FAIL with `uninitialized constant Site::Maps`.

- [ ] **Step 2: Implement the projection**

`app/lib/site/maps/conic_equal_area.rb`:

```ruby
module Site
  module Maps
    # d3-geo's conic equal-area projection (geoConicEqualArea), ported so the
    # server can draw maps without Node. It is d3's projection() pipeline:
    # rotate the longitude (wrapping into ±180°, which is what puts Attu at
    # +173° beside the rest of Alaska), project, then scale and translate
    # relative to the projected center, with y flipped to grow downward as
    # SVG's does. The tests pin it to d3's own output.
    class ConicEqualArea
      RADIANS = Math::PI / 180

      attr_reader :parallels

      def initialize(parallels:, rotate:, center: [ 0.0, 0.0 ], scale: 1.0, translate: [ 0.0, 0.0 ])
        @parallels = parallels
        phi0, phi1 = parallels.map { |degrees| degrees * RADIANS }
        sin0 = Math.sin(phi0)
        @n = (sin0 + Math.sin(phi1)) / 2
        raise ArgumentError, "parallels #{parallels.inspect} straddle the equator symmetrically" if @n.abs < 1e-6

        @c = 1 + (sin0 * ((2 * @n) - sin0))
        @r0 = Math.sqrt(@c) / @n
        @rotate = rotate * RADIANS
        @scale = scale
        @translate_x, @translate_y = translate
        @center_x, @center_y = raw(center[0] * RADIANS, center[1] * RADIANS)
      end

      # [x, y] for a longitude and latitude in degrees.
      def call(lon, lat)
        x, y = raw(wrap((lon * RADIANS) + @rotate), lat * RADIANS)
        [ @translate_x + (@scale * (x - @center_x)), @translate_y - (@scale * (y - @center_y)) ]
      end

      private
        def raw(longitude, latitude)
          r = Math.sqrt(@c - (2 * @n * Math.sin(latitude))) / @n
          [ r * Math.sin(longitude * @n), @r0 - (r * Math.cos(longitude * @n)) ]
        end

        def wrap(longitude)
          if longitude > Math::PI then longitude - (2 * Math::PI)
          elsif longitude < -Math::PI then longitude + (2 * Math::PI)
          else longitude
          end
        end
    end
  end
end
```

`app/lib/site/maps/projection.rb`:

```ruby
module Site
  module Maps
    # Which projection draws which boundary.
    module Projection
      # d3-geo's geoAlbersUsa at its default scale and translate: the lower
      # 48 on one conic, Alaska and Hawaii each on their own, moved into d3's
      # standard insets. Chosen by the boundary's state rather than by clip
      # extent, since every boundary knows its state.
      SCALE = 1070.0
      TRANSLATE_X = 480.0
      TRANSLATE_Y = 250.0

      LOWER_48 = ConicEqualArea.new(
        parallels: [ 29.5, 45.5 ], rotate: 96, center: [ -0.6, 38.7 ],
        scale: SCALE, translate: [ TRANSLATE_X, TRANSLATE_Y ]
      )
      INSETS = {
        "AK" => ConicEqualArea.new(
          parallels: [ 55, 65 ], rotate: 154, center: [ -2, 58.5 ],
          scale: SCALE * 0.35, translate: [ TRANSLATE_X - (0.307 * SCALE), TRANSLATE_Y + (0.201 * SCALE) ]
        ),
        "HI" => ConicEqualArea.new(
          parallels: [ 8, 18 ], rotate: 157, center: [ -3, 19.9 ],
          scale: SCALE, translate: [ TRANSLATE_X - (0.205 * SCALE), TRANSLATE_Y + (0.212 * SCALE) ]
        )
      }.freeze

      module_function

      def albers_usa(state)
        INSETS.fetch(state, LOWER_48)
      end

      # A unit-scale conic fitted to one state: centered on its middle
      # longitude, standard parallels at 1/6 and 5/6 of its latitude range,
      # so no state is drawn rotated the way a national projection tilts the
      # ones near its edges. Canvas scales the result to pixels.
      def fitted(rings)
        points = rings.flatten(1)
        west, east = points.map(&:first).minmax
        south, north = points.map(&:last).minmax
        inset = (north - south) / 6.0
        ConicEqualArea.new(parallels: [ south + inset, north - inset ], rotate: -((west + east) / 2.0))
      end
    end
  end
end
```

Run: `bin/rails test test/lib/site/maps/conic_equal_area_test.rb test/lib/site/maps/projection_test.rb`
Expected: PASS

- [ ] **Step 3: Write the failing path tests**

`test/lib/site/maps/path_test.rb`:

```ruby
require "test_helper"

class Site::Maps::PathTest < ActiveSupport::TestCase
  test "simplify keeps a real feature and drops points within tolerance of it" do
    spike = [ [ 0, 0 ], [ 1, 1.55 ], [ 2, 3 ], [ 3, 1.45 ], [ 4, 0 ] ]

    assert_equal [ [ 0, 0 ], [ 2, 3 ], [ 4, 0 ] ], Site::Maps::Path.simplify(spike, 0.5)
  end

  test "simplify flattens noise below tolerance" do
    noisy = [ [ 0, 0 ], [ 1, 0.1 ], [ 2, -0.1 ], [ 3, 0.2 ], [ 4, 0 ] ]

    assert_equal [ [ 0, 0 ], [ 4, 0 ] ], Site::Maps::Path.simplify(noisy, 0.5)
  end

  test "simplify handles a closed ring" do
    square = [ [ 0, 0 ], [ 5, 0 ], [ 10, 0 ], [ 10, 10 ], [ 0, 10 ], [ 0, 0 ] ]

    assert_equal [ [ 0, 0 ], [ 10, 0 ], [ 10, 10 ], [ 0, 10 ], [ 0, 0 ] ], Site::Maps::Path.simplify(square, 0.5)
  end

  test "encode writes relative one-decimal paths from rounded absolutes" do
    ring = [ [ 0.04, 0.04 ], [ 10.0, 0.0 ], [ 10.0, 10.26 ], [ 0.0, 10.0 ], [ 0.04, 0.04 ] ]

    assert_equal "M0,0l10,0l0,10.3l-10,-.3z", Site::Maps::Path.encode([ ring ])
  end

  test "encode drops repeated points and joins rings" do
    first = [ [ 0, 0 ], [ 0.01, 0.01 ], [ 1, 0 ], [ 1, 1 ], [ 0, 0 ] ]
    second = [ [ 5, 5 ], [ 6, 5 ], [ 6, 6 ], [ 5, 5 ] ]

    assert_equal "M0,0l1,0l0,1zM5,5l1,0l0,1z", Site::Maps::Path.encode([ first, second ])
  end

  test "number formats tenths compactly" do
    assert_equal %w[0 .5 -.5 12.3 12 -12 -123.4], [ 0, 5, -5, 123, 120, -120, -1234 ].map { |tenths| Site::Maps::Path.number(tenths) }
  end

  test "centroid is the area-weighted center of the largest ring" do
    small = [ [ 100, 100 ], [ 101, 100 ], [ 101, 101 ], [ 100, 101 ], [ 100, 100 ] ]
    big = [ [ 0, 0 ], [ 10, 0 ], [ 10, 4 ], [ 0, 4 ], [ 0, 0 ] ]

    x, y = Site::Maps::Path.centroid([ small, big ])
    assert_in_delta 5.0, x, 1e-9
    assert_in_delta 2.0, y, 1e-9
  end
end
```

Run: `bin/rails test test/lib/site/maps/path_test.rb`
Expected: FAIL with `uninitialized constant Site::Maps::Path`.

- [ ] **Step 4: Implement the path helpers**

`app/lib/site/maps/path.rb`:

```ruby
module Site
  module Maps
    # Pixel-space geometry for map shapes: Douglas–Peucker simplification,
    # compact SVG path data, and centroids for hover snapping.
    module Path
      module_function

      def simplify(points, tolerance)
        return points.dup if points.size <= 2 || tolerance <= 0

        keep = Array.new(points.size, false)
        keep[0] = true
        keep[-1] = true
        tolerance_sq = tolerance * tolerance
        stack = [ [ 0, points.size - 1 ] ]
        until stack.empty?
          first, last = stack.pop
          index, distance_sq = farthest(points, first, last)
          next unless index && distance_sq > tolerance_sq

          keep[index] = true
          stack.push([ first, index ], [ index, last ])
        end
        points.select.with_index { |_, index| keep[index] }
      end

      # Relative path data at one decimal: "M12.3,4l1.5,-.2…z". Deltas are
      # taken between rounded absolute positions, so the pen never drifts
      # from where each point was meant to land however long the ring.
      def encode(rings)
        rings.map { |ring| encode_ring(ring) }.join
      end

      # Tenths of a unit as the shortest decimal: 5 -> ".5", 120 -> "12".
      def number(tenths)
        whole, fraction = tenths.abs.divmod(10)
        text = if fraction.zero? then whole.to_s
        elsif whole.zero? then ".#{fraction}"
        else "#{whole}.#{fraction}"
        end
        tenths.negative? ? "-#{text}" : text
      end

      # Area-weighted center of the largest ring (shoelace formula); the
      # bounding-box center when that ring has no area.
      def centroid(rings)
        ring = rings.max_by { |candidate| signed_area(candidate).abs }
        return nil unless ring

        area = signed_area(ring)
        if area.zero?
          xs = ring.map(&:first)
          ys = ring.map(&:last)
          return [ (xs.min + xs.max) / 2.0, (ys.min + ys.max) / 2.0 ]
        end

        sum_x = 0.0
        sum_y = 0.0
        edges(ring).each do |(x0, y0), (x1, y1)|
          cross = (x0 * y1) - (x1 * y0)
          sum_x += (x0 + x1) * cross
          sum_y += (y0 + y1) * cross
        end
        [ sum_x / (6.0 * area), sum_y / (6.0 * area) ]
      end

      def signed_area(ring)
        edges(ring).sum { |(x0, y0), (x1, y1)| (x0 * y1) - (x1 * y0) } / 2.0
      end

      def farthest(points, first, last)
        ax, ay = points[first]
        bx, by = points[last]
        dx = bx - ax
        dy = by - ay
        length_sq = (dx * dx) + (dy * dy)
        best_index = nil
        best_sq = -1.0
        ((first + 1)...last).each do |index|
          px, py = points[index]
          t = length_sq.zero? ? 0.0 : ((((px - ax) * dx) + ((py - ay) * dy)) / length_sq).clamp(0.0, 1.0)
          ex = px - (ax + (t * dx))
          ey = py - (ay + (t * dy))
          distance_sq = (ex * ex) + (ey * ey)
          if distance_sq > best_sq
            best_sq = distance_sq
            best_index = index
          end
        end
        [ best_index, best_sq ]
      end

      def encode_ring(ring)
        tenths = ring.map { |x, y| [ (x * 10).round, (y * 10).round ] }
        tenths.pop if tenths.size > 1 && tenths.first == tenths.last
        start_x, start_y = tenths.first
        out = +"M#{number(start_x)},#{number(start_y)}"
        previous_x = start_x
        previous_y = start_y
        tenths.drop(1).each do |x, y|
          next if x == previous_x && y == previous_y

          out << "l#{number(x - previous_x)},#{number(y - previous_y)}"
          previous_x = x
          previous_y = y
        end
        out << "z"
      end

      def edges(ring)
        closed = ring.first == ring.last ? ring : ring + [ ring.first ]
        closed.each_cons(2)
      end
    end
  end
end
```

Run: `bin/rails test test/lib/site/maps/path_test.rb`
Expected: PASS

- [ ] **Step 5: Write the failing canvas test**

`test/lib/site/maps/canvas_test.rb`:

```ruby
require "test_helper"

class Site::Maps::CanvasTest < ActiveSupport::TestCase
  Region = Struct.new(:state, :rings)

  def box(state, west, south, east, north)
    Region.new(state, [ [ [ west, south ], [ east, south ], [ east, north ], [ west, north ], [ west, south ] ] ])
  end

  test "a state canvas fits the outline to the width and keeps its aspect ratio" do
    outline = box("CO", -109.0, 37.0, -102.0, 41.0)
    canvas = Site::Maps::Canvas.state(outline, width: 600, max_height: 480)

    assert_equal 600, canvas.width
    assert_operator canvas.height, :<, 480
    assert_equal "0 0 600 #{canvas.height}", canvas.view_box
    assert_match(/\AM[^M]+z\z/, canvas.path(outline))
  end

  test "a tall state is limited by max_height and centered across the width" do
    outline = box("NH", -72.0, 41.0, -71.0, 45.0)
    canvas = Site::Maps::Canvas.state(outline, width: 600, max_height: 300)

    assert_equal 300, canvas.height
    assert_in_delta 300.0, canvas.centroid(outline).first, 1.0
  end

  test "rings smaller than the tolerance are dropped, but a boundary never vanishes" do
    outline = box("CO", -109.0, 37.0, -102.0, 41.0)
    canvas = Site::Maps::Canvas.state(outline, width: 600, max_height: 480)
    speck = [ [ -105.0, 39.0 ], [ -104.9999, 39.0 ], [ -104.9999, 39.0001 ], [ -105.0, 39.0001 ], [ -105.0, 39.0 ] ]

    assert_equal 1, canvas.path(Region.new("CO", [ outline.rings.first, speck ])).count("M")
    assert_equal 1, canvas.path(Region.new("CO", [ speck ])).count("M")
  end

  test "the national canvas puts Alaska in the inset below and left of Maine" do
    outlines = [
      box("CA", -124.4, 32.5, -114.1, 42.0), box("ME", -71.1, 43.0, -66.9, 47.5),
      box("AK", -170.0, 52.0, -130.0, 71.0), box("HI", -160.3, 18.9, -154.8, 22.3)
    ]
    canvas = Site::Maps::Canvas.national(outlines, width: 960)
    alaska_x, alaska_y = canvas.centroid(outlines[2])
    maine_x, maine_y = canvas.centroid(outlines[1])

    assert_equal 960, canvas.width
    assert_operator alaska_x, :<, maine_x
    assert_operator alaska_y, :>, maine_y
  end
end
```

Run: `bin/rails test test/lib/site/maps/canvas_test.rb`
Expected: FAIL with `uninitialized constant Site::Maps::Canvas`.

- [ ] **Step 6: Implement the canvas**

`app/lib/site/maps/canvas.rb`:

```ruby
module Site
  module Maps
    # One map's pixel frame: it projects boundaries, fits them into a width
    # (and optional max height), and hands back simplified path data. The
    # frame is fitted around the boundaries passed in (every outline for a
    # national map, one outline for a state map); anything else drawn on the
    # canvas lands in that same frame.
    class Canvas
      attr_reader :width, :height

      def self.national(outlines, width: 960, tolerance: 0.5, padding: 2)
        new(outlines, projector: ->(boundary) { Projection.albers_usa(boundary.state) },
            width: width, max_height: nil, padding: padding, tolerance: tolerance)
      end

      def self.state(outline, width: 600, max_height: 480, tolerance: 0.5, padding: 4)
        projection = Projection.fitted(outline.rings)
        new([ outline ], projector: ->(_boundary) { projection },
            width: width, max_height: max_height, padding: padding, tolerance: tolerance)
      end

      def initialize(frame_boundaries, projector:, width:, max_height:, padding:, tolerance:)
        @projector = projector
        @tolerance = tolerance
        @projected = {}
        @width = width

        xs = []
        ys = []
        frame_boundaries.each do |boundary|
          projected_rings(boundary).each do |ring|
            ring.each do |x, y|
              xs << x
              ys << y
            end
          end
        end
        raise ArgumentError, "no points to frame" if xs.empty?

        @min_x, max_x = xs.minmax
        @min_y, max_y = ys.minmax
        span_x = [ max_x - @min_x, Float::EPSILON ].max
        span_y = [ max_y - @min_y, Float::EPSILON ].max
        inner_width = width - (2 * padding)
        @scale = inner_width / span_x
        @scale = [ @scale, (max_height - (2 * padding)) / span_y ].min if max_height
        @offset_x = padding + ((inner_width - (span_x * @scale)) / 2.0)
        @offset_y = padding
        # round(6) first: a height-limited frame computes max_height back out
        # of a float product, and 300.0000001.ceil would be 301.
        @height = ((span_y * @scale) + (2 * padding)).round(6).ceil
        @height = [ @height, max_height ].min if max_height
      end

      def view_box
        "0 0 #{@width} #{@height}"
      end

      # Rings smaller than the tolerance are dropped, but a boundary never
      # disappears entirely: when every ring is sub-pixel (Manhattan's
      # districts on the national map), the largest is kept unsimplified so
      # hover snapping and keyboard stepping can still reach it.
      def path(boundary)
        rings = pixel_rings(boundary)
        kept = rings.reject { |ring| tiny?(ring) }.filter_map do |ring|
          simple = Path.simplify(ring, @tolerance)
          simple if simple.uniq.size >= 3
        end
        kept = [ rings.max_by { |ring| Path.signed_area(ring).abs } ].compact if kept.empty?
        Path.encode(kept)
      end

      def centroid(boundary)
        Path.centroid(pixel_rings(boundary))&.map { |value| value.round(1) }
      end

      private
        def projected_rings(boundary)
          @projected[boundary] ||= begin
            projection = @projector.call(boundary)
            boundary.rings.map { |ring| ring.map { |lon, lat| projection.call(lon, lat) } }
          end
        end

        def pixel_rings(boundary)
          projected_rings(boundary).map do |ring|
            ring.map { |x, y| [ @offset_x + ((x - @min_x) * @scale), @offset_y + ((y - @min_y) * @scale) ] }
          end
        end

        def tiny?(ring)
          xs = ring.map(&:first)
          ys = ring.map(&:last)
          (xs.max - xs.min) < @tolerance && (ys.max - ys.min) < @tolerance
        end
    end
  end
end
```

Run: `bin/rails test test/lib/site/maps/`
Expected: PASS (every test in the four files).

- [ ] **Step 7: Full suite, lint, commit**

Run: `bin/rails test && bin/rubocop`
Expected: all pass, no offenses.

```bash
git add app/lib/site/maps/conic_equal_area.rb app/lib/site/maps/projection.rb app/lib/site/maps/path.rb app/lib/site/maps/canvas.rb \
  test/lib/site/maps/conic_equal_area_test.rb test/lib/site/maps/projection_test.rb test/lib/site/maps/path_test.rb test/lib/site/maps/canvas_test.rb
git commit -m "Project, fit and simplify map geometry in Ruby, matching d3-geo's Albers."
```

---

### Task 3: Colors, tooltips, and the three map builders (wave 2, Grok)

Runs in the main checkout after the orchestrator merges Tasks 1 and 2 into `district-maps`.

**Files:**
- Modify: `app/lib/site/format.rb` (add `leader`; refactor `rating_word` onto it)
- Create: `app/lib/site/maps/palette.rb`, `app/lib/site/maps/tips.rb`, `app/lib/site/maps/forecasts.rb`, `app/lib/site/maps/shape.rb`, `app/lib/site/maps/district_shape.rb`, `app/lib/site/maps/senate_map.rb`, `app/lib/site/maps/house_map.rb`, `app/lib/site/maps/state_map.rb`
- Test: `test/lib/site/format_test.rb` (append), `test/lib/site/maps/palette_test.rb`, `test/lib/site/maps/tips_test.rb`, `test/lib/site/maps/senate_map_test.rb`, `test/lib/site/maps/house_map_test.rb`, `test/lib/site/maps/state_map_test.rb`

**Interfaces:**
- Consumes:
  - Task 1: `Boundary.outlines`, `Boundary.districts`, `create_boundary(...)`.
  - Task 2: `Canvas.national`, `Canvas.state`, `#path`, `#centroid`, `#view_box`.
  - Existing: `Site::Format.percent`, `.margin`, `.rating_word`, `PARTY_LABEL`; `Site::RaceSides.for`; `Forecast.latest_for_races(variant:)`; `Pol::Params.fetch!(:site, :tossup_band_pp)`; `Ingest::Sources.cycle`; `Race::STATE_NAMES`.
- Produces the payload every map partial renders:

```ruby
{
  key: String,          # "senate", "senate-locator", "house", "state-NY", "dashboard-senate", "dashboard-house"
  view_box: String,     # "0 0 960 563"
  aria_label: String,
  interactive: Boolean,
  groups: [ { state: String | nil, clip_id: String | nil, outline_id: String | nil, outline_d: String | nil,
              shapes: [ Site::Maps::Shape ], highlight_d: String | nil } ],
  legend: { ramps: [ { label:, from:, to: } ], swatches: [ { label:, color: } ], caption: String } | nil
}
# Site::Maps::Shape: key, d, slug (nil = not a link), cx, cy,
#   fills: { excl_internals: "#rrggbb", incl_internals: "#rrggbb" },
#   tips:  { excl_internals: tip, incl_internals: tip } | nil
# tip: { header:, subheader:, rows: [ { value:, label:, party: String | nil, swatch: Boolean } ], footer: (optional) }
```

- Builder signatures:
  - `Site::Maps::SenateMap.build(highlight: nil, key: nil, tolerance: nil)`
  - `Site::Maps::HouseMap.build(key: "house", tolerance: 0.5)`
  - `Site::Maps::StateMap.build(race)`
- Each builder returns nil when the boundaries it needs don't exist.

- [ ] **Step 1: `Site::Format.leader` (test first)**

Append to `test/lib/site/format_test.rb`, inside the class:

```ruby
  test "leader is the highest win probability, ties going to dem, then rep" do
    assert_equal [ "rep", 0.6 ], Site::Format.leader(p_dem_win: 0.4, p_rep_win: 0.6, p_other_win: 0.0)
    assert_equal [ "dem", 0.5 ], Site::Format.leader(p_dem_win: 0.5, p_rep_win: 0.5, p_other_win: 0.0)
    assert_equal [ "other", 0.7 ], Site::Format.leader(p_dem_win: 0.1, p_rep_win: 0.2, p_other_win: 0.7)
  end
```

Run: `bin/rails test test/lib/site/format_test.rb`
Expected: FAIL with `undefined method 'leader'`.

In `app/lib/site/format.rb`, replace `rating_word` with this pair:

```ruby
    # ["dem", 0.62]: whichever of the three win probabilities is highest,
    # ties going to dem, then rep.
    def leader(p_dem_win:, p_rep_win:, p_other_win:)
      [ [ "dem", p_dem_win ], [ "rep", p_rep_win ], [ "other", p_other_win ] ].max_by { |_, probability| probability }
    end

    # "Tossup" when the leading side's win probability is at or under the
    # tossup band (site.tossup_band_pp, e.g. 65.0); otherwise
    # "Favors {Party}". `tossup_band_pp` is points (0..100), matching how
    # it's stored in config/model_params.yml. An uncontested race is a
    # Race-level fact this function doesn't see — callers special-case it
    # before reaching here.
    def rating_word(p_dem_win:, p_rep_win:, p_other_win:, tossup_band_pp:)
      party, probability = leader(p_dem_win: p_dem_win, p_rep_win: p_rep_win, p_other_win: p_other_win)
      return "Tossup" if probability * 100.0 <= tossup_band_pp

      "Favors #{PARTY_LABEL.fetch(party)}"
    end
```

Run: `bin/rails test test/lib/site/format_test.rb`
Expected: PASS (the existing rating_word tests too).

- [ ] **Step 2: Palette (test first)**

`test/lib/site/maps/palette_test.rb`:

```ruby
require "test_helper"

class Site::Maps::PaletteTest < ActiveSupport::TestCase
  FakeRace = Struct.new(:uncontested, :uncontested_party) do
    def uncontested? = uncontested
  end
  FakeForecast = Struct.new(:p_dem_win, :p_rep_win, :p_other_win)

  test "the party hues are charts/theme.js's" do
    theme = Rails.root.join("app/javascript/charts/theme.js").read
    Site::Maps::Palette::PARTY.each_value { |hex| assert_includes theme, hex }
  end

  test "mix blends from white toward the hue" do
    assert_equal "#ffffff", Site::Maps::Palette.mix("#1d4ed8", 0.0)
    assert_equal "#1d4ed8", Site::Maps::Palette.mix("#1d4ed8", 1.0)
    assert_equal "#8ea7ec", Site::Maps::Palette.mix("#1d4ed8", 0.5)
  end

  test "a certain race is the full hue; an even one is the floor tint" do
    assert_equal "#1d4ed8", Site::Maps::Palette.shade("dem", 1.0)
    assert_equal Site::Maps::Palette.mix("#b91c1c", Site::Maps::Palette::FLOOR), Site::Maps::Palette.shade("rep", 0.5)
    assert_equal Site::Maps::Palette.shade("rep", 0.5), Site::Maps::Palette.shade("rep", 0.3)
  end

  test "fill follows the leader, the uncontested party, or the missing forecast" do
    contested = FakeRace.new(false, nil)

    assert_equal Site::Maps::Palette.shade("dem", 0.62), Site::Maps::Palette.fill(race: contested, forecast: FakeForecast.new(0.62, 0.38, 0.0))
    assert_equal Site::Maps::Palette.shade("other", 0.7), Site::Maps::Palette.fill(race: contested, forecast: FakeForecast.new(0.1, 0.2, 0.7))
    assert_equal Site::Maps::Palette::NO_FORECAST, Site::Maps::Palette.fill(race: contested, forecast: nil)
    assert_equal "#b91c1c", Site::Maps::Palette.fill(race: FakeRace.new(true, "rep"), forecast: nil)
    assert_equal "#64748b", Site::Maps::Palette.fill(race: FakeRace.new(true, "ind"), forecast: nil)
  end

  test "the legend states the tossup band from params" do
    legend = Site::Maps::Palette.legend(no_race_label: "No Senate race this year")

    assert_equal %w[Dem Rep], legend[:ramps].map { |ramp| ramp[:label] }
    assert_includes legend[:swatches].map { |swatch| swatch[:label] }, "No Senate race this year"
    assert_includes legend[:caption], "#{Pol::Params.fetch!(:site, :tossup_band_pp).round}%"
  end
end
```

Run: `bin/rails test test/lib/site/maps/palette_test.rb`
Expected: FAIL with `uninitialized constant Site::Maps::Palette`.

`app/lib/site/maps/palette.rb`:

```ruby
module Site
  module Maps
    # Fill colors for map shapes. PARTY is app/javascript/charts/theme.js's
    # PARTY, so a map and the charts beside it cannot disagree about Dem-blue.
    module Palette
      PARTY = { "dem" => "#1d4ed8", "rep" => "#b91c1c", "other" => "#64748b" }.freeze
      NO_FORECAST = "#e2e8f0".freeze
      NO_RACE = "#f8fafc".freeze
      # How far a dead-even race is mixed from white toward its leader's
      # hue; the remaining 1 − FLOOR is spread linearly across a 50% to 100%
      # win probability.
      FLOOR = 0.2

      module_function

      def fill(race:, forecast:)
        return PARTY.fetch(party_key(race.uncontested_party)) if race.uncontested? && race.uncontested_party.present?
        return NO_FORECAST unless forecast

        party, probability = Site::Format.leader(p_dem_win: forecast.p_dem_win, p_rep_win: forecast.p_rep_win, p_other_win: forecast.p_other_win)
        shade(party, probability)
      end

      def shade(party, probability)
        strength = ((probability - 0.5) / 0.5).clamp(0.0, 1.0)
        mix(PARTY.fetch(party), FLOOR + ((1 - FLOOR) * strength))
      end

      # White blended toward `hex` by `amount`: 0 is white, 1 is `hex`.
      def mix(hex, amount)
        channels = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
        "#" + channels.map { |channel| (255 + ((channel - 255) * amount)).round.to_s(16).rjust(2, "0") }.join
      end

      # Races say dem/rep/ind/other; the palette folds ind into other.
      def party_key(party)
        PARTY.key?(party.to_s) ? party.to_s : "other"
      end

      def legend(no_race_label: nil)
        swatches = [ { label: "No forecast yet", color: NO_FORECAST } ]
        swatches << { label: no_race_label, color: NO_RACE } if no_race_label
        {
          ramps: %w[dem rep].map { |party| { label: Site::Format::PARTY_LABEL.fetch(party), from: shade(party, 0.5), to: shade(party, 1.0) } },
          swatches: swatches,
          caption: "Darker is likelier. The palest shades are tossups: the leading side wins " \
                   "#{Pol::Params.fetch!(:site, :tossup_band_pp).round}% of simulations or fewer."
        }
      end
    end
  end
end
```

Run: `bin/rails test test/lib/site/maps/palette_test.rb`
Expected: PASS

- [ ] **Step 3: Tips, forecasts, and Shape (test first)**

`test/lib/site/maps/tips_test.rb`:

```ruby
require "test_helper"

class Site::Maps::TipsTest < ActiveSupport::TestCase
  test "a forecast race lists nonzero chances, highest first, then the margin" do
    tip = Site::Maps::Tips.for(races(:senate_maine), forecasts(:maine_forecast), sides: %w[dem rep])

    assert_equal "Maine Senate", tip[:header]
    assert_equal "Tossup", tip[:subheader]
    assert_equal [
      { value: "62%", label: "Dem", party: "dem", swatch: true },
      { value: "38%", label: "Rep", party: "rep", swatch: true },
      { value: "D+3.2", label: "estimated margin", party: "dem", swatch: false }
    ], tip[:rows]
    assert_not tip.key?(:footer)
  end

  test "no forecast says so and has no rows" do
    tip = Site::Maps::Tips.for(races(:house_ny_17), nil, sides: %w[dem rep])

    assert_equal "No forecast yet", tip[:subheader]
    assert_empty tip[:rows]
  end

  test "an uncontested race says so" do
    race = races(:house_ny_17)
    race.update!(uncontested: true, uncontested_party: :dem)

    assert_equal "Uncontested", Site::Maps::Tips.for(race, nil, sides: %w[dem rep])[:subheader]
  end

  test "an even margin carries no party, and other races go in the footer" do
    forecast = forecasts(:maine_forecast)
    forecast.mean_margin = 0.04
    tip = Site::Maps::Tips.for(races(:senate_maine), forecast, sides: %w[dem rep], also: "Maine Senate (special)")

    assert_nil tip[:rows].last[:party]
    assert_equal "Even", tip[:rows].last[:value]
    assert_equal "Also on the ballot: Maine Senate (special)", tip[:footer]
  end

  test "the internals view falls back to the published row" do
    maine = races(:senate_maine)
    by_variant = Site::Maps::Forecasts.latest_by_variant([ maine.id ])

    assert_equal forecasts(:maine_forecast), by_variant[:excl_internals][maine.id]
    assert_equal forecasts(:maine_forecast), by_variant[:incl_internals][maine.id]
    assert_equal %i[excl_internals incl_internals], Site::Maps::Forecasts::VARIANTS
  end
end
```

Run: `bin/rails test test/lib/site/maps/tips_test.rb`
Expected: FAIL with `uninitialized constant Site::Maps::Tips`.

`app/lib/site/maps/forecasts.rb`:

```ruby
module Site
  module Maps
    # The latest succeeded run's forecasts for a set of races, keyed by
    # variant, then race id. The internals view falls back to the published
    # row wherever a pre-toggle run wrote only one: the same stand-in
    # VariantsHelper#forecasts_by_variant makes for a single race.
    module Forecasts
      VARIANTS = Forecast.variants.keys.map(&:to_sym).freeze

      module_function

      def latest_by_variant(race_ids)
        published = Forecast.latest_for_races.where(race_id: race_ids).index_by(&:race_id)
        internals = Forecast.latest_for_races(variant: :incl_internals).where(race_id: race_ids).index_by(&:race_id)
        { excl_internals: published, incl_internals: published.merge(internals) }
      end
    end
  end
end
```

`app/lib/site/maps/shape.rb`:

```ruby
module Site
  module Maps
    # One drawable region of a map payload. `fills` and `tips` are keyed by
    # forecast variant; `slug` and `tips` are nil for a shape that isn't a
    # link (no race there, or a locator).
    Shape = Struct.new(:key, :d, :slug, :cx, :cy, :fills, :tips, keyword_init: true)
  end
end
```

`app/lib/site/maps/tips.rb`:

```ruby
module Site
  module Maps
    # Tooltip content for one race's shape in one forecast variant. Every word
    # is built here. map_chart_controller only places strings, and maps each
    # row's party to a color through charts/theme.js.
    module Tips
      # The timeline tooltip's series names.
      NAMES = { "dem" => "Dem", "rep" => "Rep", "other" => "Other" }.freeze

      module_function

      # sides: [side_a_party, side_b_party] for the margin, as Site::RaceSides
      # resolves them. also: other races on the same shape, for the footer.
      def for(race, forecast, sides:, also: nil)
        {
          header: race.name,
          subheader: rating(race, forecast),
          rows: rows(race, forecast, sides),
          footer: also && "Also on the ballot: #{also}"
        }.compact
      end

      # RacesHelper#rating_word_for's rule; lib code can't call a view helper.
      def rating(race, forecast)
        return "Uncontested" if uncontested?(race)
        return "No forecast yet" unless forecast

        Site::Format.rating_word(p_dem_win: forecast.p_dem_win, p_rep_win: forecast.p_rep_win, p_other_win: forecast.p_other_win,
                                 tossup_band_pp: Pol::Params.fetch!(:site, :tossup_band_pp))
      end

      def rows(race, forecast, sides)
        return [] if forecast.nil? || uncontested?(race)

        chances = { "dem" => forecast.p_dem_win, "rep" => forecast.p_rep_win, "other" => forecast.p_other_win }
          .select { |_, probability| probability.to_f.positive? }
          .sort_by.with_index { |(_, probability), index| [ -probability, index ] }
          .map { |party, probability| { value: Site::Format.percent(probability), label: NAMES.fetch(party), party: party, swatch: true } }
        chances << margin_row(forecast.mean_margin, sides) unless forecast.mean_margin.nil?
        chances
      end

      def margin_row(margin, sides)
        side_a, side_b = sides
        rounded = margin.round(1)
        party = rounded.zero? ? nil : Palette.party_key(rounded.positive? ? side_a : side_b)
        { value: Site::Format.margin(margin, side_a_party: side_a, side_b_party: side_b), label: "estimated margin", party: party, swatch: false }
      end

      def uncontested?(race)
        race.uncontested? && race.uncontested_party.present?
      end
    end
  end
end
```

Run: `bin/rails test test/lib/site/maps/tips_test.rb`
Expected: PASS

- [ ] **Step 4: The Senate map (test first)**

`test/lib/site/maps/senate_map_test.rb`:

```ruby
require "test_helper"

class Site::Maps::SenateMapTest < ActiveSupport::TestCase
  setup do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "FL", box: [ -87.6, 24.5, -80.0, 31.0 ])
    create_boundary(state: "VT", box: [ -73.4, 42.7, -71.5, 45.0 ])
  end

  def shapes(payload)
    payload[:groups].sole[:shapes].index_by(&:key)
  end

  test "nil until boundaries exist" do
    Boundary.delete_all

    assert_nil Site::Maps::SenateMap.build
  end

  test "every state is a shape; a state with a race links to it and carries both variants" do
    payload = Site::Maps::SenateMap.build
    maine = shapes(payload)["ME"]

    assert_equal "senate", payload[:key]
    assert payload[:interactive]
    assert_match(/\A0 0 960 \d+\z/, payload[:view_box])
    assert_equal %w[FL ME VT], shapes(payload).keys.sort
    assert_equal races(:senate_maine).slug, maine.slug
    assert_equal Site::Maps::Palette.fill(race: races(:senate_maine), forecast: forecasts(:maine_forecast)), maine.fills[:excl_internals]
    assert_equal maine.fills[:excl_internals], maine.fills[:incl_internals]
    assert_equal "Maine Senate", maine.tips[:excl_internals][:header]
    assert_equal Site::Maps::Palette::NO_FORECAST, shapes(payload)["FL"].fills[:excl_internals]
    assert_nil shapes(payload)["VT"].slug
    assert_nil shapes(payload)["VT"].tips
    assert_equal Site::Maps::Palette::NO_RACE, shapes(payload)["VT"].fills[:excl_internals]
    assert_includes payload[:legend][:swatches].map { |swatch| swatch[:label] }, "No Senate race this year"
  end

  test "an internals row recolors only the internals view" do
    Forecast.create!(model_run: model_runs(:model_run_one), race: races(:senate_maine), variant: :incl_internals,
                     p_dem_win: 0.2, p_rep_win: 0.8, p_other_win: 0.0, mean_margin: -6.0)
    maine = shapes(Site::Maps::SenateMap.build)["ME"]

    assert_equal Site::Maps::Palette.shade("rep", 0.8), maine.fills[:incl_internals]
    assert_equal "80%", maine.tips[:incl_internals][:rows].first[:value]
    assert_equal "62%", maine.tips[:excl_internals][:rows].first[:value]
  end

  test "a state with two races is filled by the closer one and names the other" do
    special = Race.create!(office: :senate, state: "ME", cycle: 2026, special: true, slug: "senate-me-2026-special-map-test", lean: 0.0)
    Forecast.create!(model_run: model_runs(:model_run_one), race: special, p_dem_win: 0.05, p_rep_win: 0.95, p_other_win: 0.0, mean_margin: -20.0)
    maine = shapes(Site::Maps::SenateMap.build)["ME"]

    assert_equal races(:senate_maine).slug, maine.slug
    assert_equal "Also on the ballot: Maine Senate (special)", maine.tips[:excl_internals][:footer]
  end

  test "the locator colors only the highlighted state and is not interactive" do
    payload = Site::Maps::SenateMap.build(highlight: races(:senate_maine))

    assert_equal "senate-locator", payload[:key]
    assert_not payload[:interactive]
    assert_nil payload[:legend]
    assert_equal Site::Maps::Palette::NO_RACE, shapes(payload)["FL"].fills[:excl_internals]
    assert_equal Site::Maps::Palette.fill(race: races(:senate_maine), forecast: forecasts(:maine_forecast)), shapes(payload)["ME"].fills[:excl_internals]
    assert shapes(payload).values.all? { |shape| shape.slug.nil? && shape.tips.nil? }
    assert_equal shapes(payload)["ME"].d, payload[:groups].sole[:highlight_d]
  end
end
```

Run: `bin/rails test test/lib/site/maps/senate_map_test.rb`
Expected: FAIL with `uninitialized constant Site::Maps::SenateMap`.

`app/lib/site/maps/senate_map.rb`:

```ruby
module Site
  module Maps
    # The national Senate map: every state outline, filled by its Senate race
    # on this cycle's ballot. With `highlight:` it is a Senate race page's
    # locator instead, with no links or tooltips and only the race's own
    # state colored and outlined.
    class SenateMap
      WIDTH = 960
      TOLERANCE = 0.5
      LOCATOR_TOLERANCE = 1.0
      NO_RACE_LABEL = "No Senate race this year".freeze

      def self.build(highlight: nil, key: nil, tolerance: nil)
        new(
          highlight: highlight,
          key: key || (highlight ? "senate-locator" : "senate"),
          tolerance: tolerance || (highlight ? LOCATOR_TOLERANCE : TOLERANCE)
        ).build
      end

      def initialize(highlight:, key:, tolerance:)
        @highlight = highlight
        @key = key
        @tolerance = tolerance
      end

      def build
        outlines = Boundary.outlines.order(:state).to_a
        return nil if outlines.empty?

        canvas = Canvas.national(outlines, width: WIDTH, tolerance: @tolerance)
        races_by_state = Race.senate.includes(:candidates).order(:slug).to_a.group_by(&:state)
        forecasts = Forecasts.latest_by_variant(races_by_state.values.flatten.map(&:id))
        shapes = outlines.map { |outline| shape_for(outline, canvas, races_by_state.fetch(outline.state, []), forecasts) }

        {
          key: @key,
          view_box: canvas.view_box,
          aria_label: aria_label,
          interactive: @highlight.nil?,
          groups: [ { state: nil, clip_id: nil, outline_id: nil, outline_d: nil, shapes: shapes, highlight_d: highlight_d(shapes) } ],
          legend: @highlight ? nil : Palette.legend(no_race_label: NO_RACE_LABEL)
        }
      end

      private
        def shape_for(outline, canvas, races, forecasts)
          cx, cy = canvas.centroid(outline)
          attributes = { key: outline.state, d: canvas.path(outline), cx: cx, cy: cy }
          return locator_shape(attributes, outline, forecasts) if @highlight

          race = races.min_by { |candidate| closeness(forecasts[:excl_internals][candidate.id]) }
          return Shape.new(**attributes, fills: Forecasts::VARIANTS.index_with { Palette::NO_RACE }) unless race

          sides = Site::RaceSides.for(race.candidates)
          others = (races - [ race ]).map { |other| display_name(other) }.to_sentence.presence
          Shape.new(
            **attributes,
            slug: race.slug,
            fills: Forecasts::VARIANTS.index_with { |variant| Palette.fill(race: race, forecast: forecasts[variant][race.id]) },
            tips: Forecasts::VARIANTS.index_with { |variant| Tips.for(race, forecasts[variant][race.id], sides: sides, also: others) }
          )
        end

        def locator_shape(attributes, outline, forecasts)
          fills = Forecasts::VARIANTS.index_with do |variant|
            next Palette::NO_RACE unless outline.state == @highlight.state

            Palette.fill(race: @highlight, forecast: forecasts[variant][@highlight.id])
          end
          Shape.new(**attributes, fills: fills)
        end

        # The leading side's win probability: the lower, the closer the race.
        # A race with no forecast sorts after every forecast one.
        def closeness(forecast)
          return 2.0 unless forecast

          Site::Format.leader(p_dem_win: forecast.p_dem_win, p_rep_win: forecast.p_rep_win, p_other_win: forecast.p_other_win).last
        end

        def display_name(race)
          race.special? ? "#{race.name} (special)" : race.name
        end

        def highlight_d(shapes)
          return nil unless @highlight

          shapes.find { |shape| shape.key == @highlight.state }&.d
        end

        def aria_label
          if @highlight
            "Locator map with #{Race::STATE_NAMES.fetch(@highlight.state, @highlight.state)} highlighted"
          else
            "Map of the Senate races on the #{Ingest::Sources.cycle} ballot, each state shaded by its race's win probability"
          end
        end
    end
  end
end
```

Run: `bin/rails test test/lib/site/maps/senate_map_test.rb`
Expected: PASS

- [ ] **Step 5: The House and state maps (test first)**

`test/lib/site/maps/house_map_test.rb`:

```ruby
require "test_helper"

class Site::Maps::HouseMapTest < ActiveSupport::TestCase
  setup do
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])
    create_boundary(state: "NY", district: 18, box: [ -74.9, 41.2, -74.2, 41.9 ])
    create_boundary(state: "VT", box: [ -73.4, 42.7, -71.5, 45.0 ])
  end

  test "one clipped group per state that has districts" do
    payload = Site::Maps::HouseMap.build
    group = payload[:groups].sole

    assert_equal "house", payload[:key]
    assert_equal "NY", group[:state]
    assert_equal "house-clip-NY", group[:clip_id]
    assert_equal "house-outline-NY", group[:outline_id]
    assert group[:outline_d].start_with?("M")
    assert_equal %w[NY-17 NY-18], group[:shapes].map(&:key)
    assert_nil group[:highlight_d]
  end

  test "a district with a race links to it; one without is filled as no race" do
    shapes = Site::Maps::HouseMap.build[:groups].sole[:shapes].index_by(&:key)

    assert_equal races(:house_ny_17).slug, shapes["NY-17"].slug
    assert_equal Site::Maps::Palette::NO_FORECAST, shapes["NY-17"].fills[:excl_internals]
    assert_equal "NY-17", shapes["NY-17"].tips[:excl_internals][:header]
    assert_nil shapes["NY-18"].slug
    assert_equal Site::Maps::Palette::NO_RACE, shapes["NY-18"].fills[:incl_internals]
  end

  test "races without a boundary are simply not drawn" do
    Race.create!(office: :house, state: "ZZ", district: 1, cycle: 2026, slug: "house-zz-1-map-test", baseline_margin: 1.0)

    assert_equal %w[NY-17 NY-18], Site::Maps::HouseMap.build[:groups].flat_map { |group| group[:shapes] }.map(&:key)
  end

  test "the key prefixes every SVG id so two maps can share a page" do
    group = Site::Maps::HouseMap.build(key: "dashboard-house", tolerance: 1.0)[:groups].sole

    assert_equal "dashboard-house-clip-NY", group[:clip_id]
  end
end
```

`test/lib/site/maps/state_map_test.rb`:

```ruby
require "test_helper"

class Site::Maps::StateMapTest < ActiveSupport::TestCase
  setup do
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])
    create_boundary(state: "NY", district: 18, box: [ -74.9, 41.2, -74.2, 41.9 ])
  end

  test "the race's own district is outlined and its neighbors stay in the map" do
    payload = Site::Maps::StateMap.build(races(:house_ny_17))
    group = payload[:groups].sole
    shapes = group[:shapes].index_by(&:key)

    assert_equal "state-NY", payload[:key]
    assert payload[:interactive]
    assert payload[:view_box].start_with?("0 0 600 ")
    assert_equal "state-NY-clip", group[:clip_id]
    assert_equal %w[NY-17 NY-18], shapes.keys
    assert_equal shapes["NY-17"].d, group[:highlight_d]
    assert_nil payload[:legend]
  end

  test "nil when the state has no boundaries yet" do
    Boundary.delete_all

    assert_nil Site::Maps::StateMap.build(races(:house_ny_17))
  end
end
```

Run: `bin/rails test test/lib/site/maps/house_map_test.rb test/lib/site/maps/state_map_test.rb`
Expected: FAIL with `uninitialized constant Site::Maps::HouseMap`.

`app/lib/site/maps/district_shape.rb`:

```ruby
module Site
  module Maps
    # A district's Shape on any canvas, shared by the national House map and a
    # House race page's state map.
    module DistrictShape
      # Every modelled House race runs on generic dem/rep sides (see
      # RacesHelper#house_margin), so no candidates are loaded for these.
      SIDES = %w[dem rep].freeze

      module_function

      def build(boundary, canvas, race, forecasts)
        cx, cy = canvas.centroid(boundary)
        attributes = { key: "#{boundary.state}-#{boundary.district}", d: canvas.path(boundary), cx: cx, cy: cy }
        return Shape.new(**attributes, fills: Forecasts::VARIANTS.index_with { Palette::NO_RACE }) unless race

        Shape.new(
          **attributes,
          slug: race.slug,
          fills: Forecasts::VARIANTS.index_with { |variant| Palette.fill(race: race, forecast: forecasts[variant][race.id]) },
          tips: Forecasts::VARIANTS.index_with { |variant| Tips.for(race, forecasts[variant][race.id], sides: SIDES) }
        )
      end
    end
  end
end
```

`app/lib/site/maps/house_map.rb`:

```ruby
module Site
  module Maps
    # The national House map: every district on the cycle's lines. Each
    # state's districts are clipped to its shoreline outline (the legal
    # district lines run out into lakes and bays), and the outline is stroked
    # on top. Builders iterate boundaries, not races, so a race with no
    # boundary is simply not drawn.
    class HouseMap
      WIDTH = 960
      TOLERANCE = 0.5

      def self.build(key: "house", tolerance: TOLERANCE)
        new(key: key, tolerance: tolerance).build
      end

      def initialize(key:, tolerance:)
        @key = key
        @tolerance = tolerance
      end

      def build
        outlines = Boundary.outlines.order(:state).to_a
        return nil if outlines.empty?

        districts_by_state = Boundary.districts.order(:state, :district).to_a.group_by(&:state)
        canvas = Canvas.national(outlines, width: WIDTH, tolerance: @tolerance)
        races = Race.house.to_a.index_by { |race| [ race.state, race.district ] }
        forecasts = Forecasts.latest_by_variant(races.values.map(&:id))

        groups = outlines.filter_map do |outline|
          districts = districts_by_state.fetch(outline.state, [])
          next if districts.empty?

          {
            state: outline.state,
            clip_id: "#{@key}-clip-#{outline.state}",
            outline_id: "#{@key}-outline-#{outline.state}",
            outline_d: canvas.path(outline),
            shapes: districts.map { |district| DistrictShape.build(district, canvas, races[[ district.state, district.district ]], forecasts) },
            highlight_d: nil
          }
        end

        { key: @key, view_box: canvas.view_box, aria_label: aria_label, interactive: true, groups: groups, legend: Palette.legend }
      end

      private
        def aria_label
          "Map of all #{Ingest::SeedRaces::HOUSE_DISTRICTS} House districts on the #{Ingest::Sources.cycle} lines, " \
            "each shaded by its race's win probability"
        end
    end
  end
end
```

`app/lib/site/maps/state_map.rb`:

```ruby
module Site
  module Maps
    # A House race page's map: every district in the race's state, each shaded
    # by its own forecast, with the page's own district outlined. The outline
    # sits inside the state's clip, so a coastal district's highlight never
    # traces water.
    class StateMap
      WIDTH = 600
      MAX_HEIGHT = 440
      TOLERANCE = 0.5

      def self.build(race)
        new(race).build
      end

      def initialize(race)
        @race = race
        @key = "state-#{race.state}"
      end

      def build
        outline = Boundary.outlines.find_by(state: @race.state)
        districts = Boundary.districts.where(state: @race.state).order(:district).to_a
        return nil if outline.nil? || districts.empty?

        canvas = Canvas.state(outline, width: WIDTH, max_height: MAX_HEIGHT, tolerance: TOLERANCE)
        races = Race.house.where(state: @race.state).index_by(&:district)
        forecasts = Forecasts.latest_by_variant(races.values.map(&:id))
        shapes = districts.map { |district| DistrictShape.build(district, canvas, races[district.district], forecasts) }

        {
          key: @key,
          view_box: canvas.view_box,
          aria_label: "Map of #{Race::STATE_NAMES.fetch(@race.state, @race.state)}'s congressional districts with #{@race.name} outlined",
          interactive: true,
          groups: [ {
            state: @race.state,
            clip_id: "#{@key}-clip",
            outline_id: "#{@key}-outline",
            outline_d: canvas.path(outline),
            shapes: shapes,
            highlight_d: shapes.find { |shape| shape.key == "#{@race.state}-#{@race.district}" }&.d
          } ],
          legend: nil
        }
      end
    end
  end
end
```

Run: `bin/rails test test/lib/site/maps/`
Expected: PASS

- [ ] **Step 6: Full suite, lint, commit**

Run: `bin/rails test && bin/rubocop`
Expected: all pass, no offenses.

```bash
git add app/lib/site/format.rb app/lib/site/maps/palette.rb app/lib/site/maps/tips.rb app/lib/site/maps/forecasts.rb \
  app/lib/site/maps/shape.rb app/lib/site/maps/district_shape.rb app/lib/site/maps/senate_map.rb app/lib/site/maps/house_map.rb \
  app/lib/site/maps/state_map.rb test/lib/site/format_test.rb test/lib/site/maps/palette_test.rb test/lib/site/maps/tips_test.rb \
  test/lib/site/maps/senate_map_test.rb test/lib/site/maps/house_map_test.rb test/lib/site/maps/state_map_test.rb
git commit -m "Build Senate, House and state map payloads from boundaries and forecasts."
```

---

### Task 4: Map partial, Stimulus controller, CSS, and /senate and /house (wave 3, Grok)

**Files:**
- Create: `app/views/races/_map.html.erb`, `app/views/races/_map_legend.html.erb`
- Create: `app/helpers/maps_helper.rb`
- Create: `app/javascript/controllers/map_chart_controller.js` (auto-registered as `map-chart` by `eagerLoadControllersFrom`)
- Modify: `app/assets/tailwind/application.css` (append a "Maps" section after the internals-toggle rules)
- Modify: `app/views/races/senate.html.erb`, `app/views/races/house.html.erb`
- Test: `test/controllers/races_controller_test.rb` (append), `test/system/chart_interactions_test.rb` (append)

**Interfaces:**
- Consumes: the Task 3 payload and builders; `createTooltip` from `charts/tooltip`; `partyColor` from `charts/theme`; `Turbo` from `@hotwired/turbo-rails`; the `internals:changed` window event dispatched by `internals_toggle_controller.js`.
- Produces:
  - `render "races/map", payload:, show_legend: true` (Task 5 renders it with `show_legend: false`).
  - DOM contract: the wrapper has `data-testid="map-<key>"`; each linked shape is `a[data-key][data-cx][data-cy][data-map-chart-target="shape"]`; the tooltip is `[data-testid=chart-tooltip]`.

- [ ] **Step 1: Write the failing controller tests**

Append to `test/controllers/races_controller_test.rb`, inside the class:

```ruby
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
```

Run: `bin/rails test test/controllers/races_controller_test.rb`
Expected: the two new tests FAIL (no `map-senate` / `map-house` on the page).

- [ ] **Step 2: Helper and partials**

`app/helpers/maps_helper.rb`:

```ruby
module MapsHelper
  # A map payload's tooltip words as { shape key => tips by variant }, for a
  # <script type="application/json">. json_escape leaves nothing an HTML
  # parser could read as markup, including "</script>".
  def map_tips_json(payload)
    tips = payload[:groups].flat_map { |group| group[:shapes] }.select(&:tips).to_h { |shape| [ shape.key, shape.tips ] }
    json_escape(tips.to_json).html_safe
  end
end
```

`app/views/races/_map.html.erb`:

```erb
<%# locals: (payload:, show_legend: true) -%>
<%# Renders any Site::Maps payload. Each shape is drawn once and carries both
    variants' fills as custom properties; application.css picks one off
    html[data-internals]. District shapes sit inside their state's clip (the
    legal lines run out into water), and the outline is stroked on top as a
    <use> of the same path the clip uses. Tooltip words ride in one JSON
    script per map, not per-shape attributes; map_chart_controller reads it. %>
<% interactive = payload[:interactive] %>
<div class="relative w-full" data-testid="map-<%= payload[:key] %>"
     <% if interactive %>
       data-controller="map-chart" tabindex="0" role="group"
       aria-label="<%= payload[:aria_label] %>; left and right arrow keys step through races, Enter opens one"
     <% end %>>
  <svg viewBox="<%= payload[:view_box] %>" class="block h-auto w-full" role="img" aria-label="<%= payload[:aria_label] %>">
    <defs>
      <% payload[:groups].each do |group| %>
        <% next unless group[:outline_id] %>
        <path id="<%= group[:outline_id] %>" d="<%= group[:outline_d] %>" fill-rule="evenodd" />
        <clipPath id="<%= group[:clip_id] %>" clip-rule="evenodd"><use href="#<%= group[:outline_id] %>" /></clipPath>
      <% end %>
    </defs>
    <% payload[:groups].each do |group| %>
      <g<% if group[:clip_id] %> clip-path="url(#<%= group[:clip_id] %>)"<% end %>>
        <% group[:shapes].each do |shape| %>
          <% style = "--fill-excl:#{shape.fills[:excl_internals]};--fill-incl:#{shape.fills[:incl_internals]}" %>
          <% if interactive && shape.slug %>
            <a href="<%= race_path(shape.slug) %>" tabindex="-1" data-map-chart-target="shape" data-key="<%= shape.key %>" data-cx="<%= shape.cx %>" data-cy="<%= shape.cy %>"><path class="map-shape" d="<%= shape.d %>" fill-rule="evenodd" style="<%= style %>" /></a>
          <% else %>
            <path class="map-shape" d="<%= shape.d %>" fill-rule="evenodd" style="<%= style %>" data-key="<%= shape.key %>" />
          <% end %>
        <% end %>
        <% if group[:highlight_d] %>
          <path class="map-highlight" d="<%= group[:highlight_d] %>" fill-rule="evenodd" />
        <% end %>
      </g>
    <% end %>
    <% payload[:groups].each do |group| %>
      <% if group[:outline_id] %><use href="#<%= group[:outline_id] %>" class="map-outline" /><% end %>
    <% end %>
  </svg>
  <% if interactive %>
    <script type="application/json" data-map-chart-target="tips"><%= map_tips_json(payload) %></script>
  <% end %>
  <% if show_legend && payload[:legend] %>
    <%= render "races/map_legend", legend: payload[:legend] %>
  <% end %>
</div>
```

`app/views/races/_map_legend.html.erb`:

```erb
<%# locals: (legend:) -%>
<div class="mt-2" data-testid="map-legend">
  <div class="flex flex-wrap items-center gap-x-5 gap-y-1 text-xs text-slate-600">
    <% legend[:ramps].each do |ramp| %>
      <span class="flex items-center gap-1.5">
        <span class="inline-block h-2.5 w-12 rounded-sm" style="background:linear-gradient(to right, <%= ramp[:from] %>, <%= ramp[:to] %>)"></span>
        <%= ramp[:label] %>
      </span>
    <% end %>
    <% legend[:swatches].each do |swatch| %>
      <span class="flex items-center gap-1.5">
        <span class="inline-block h-2.5 w-2.5 rounded-sm ring-1 ring-slate-300" style="background:<%= swatch[:color] %>"></span>
        <%= swatch[:label] %>
      </span>
    <% end %>
  </div>
  <p class="mt-1 text-xs text-slate-400"><%= legend[:caption] %></p>
</div>
```

- [ ] **Step 3: CSS**

Append to `app/assets/tailwind/application.css`, directly after the internals-toggle rules (the `tr[data-internal-poll]` block):

```css
/* ---------------------------------------------------------------------------
   Maps (app/views/races/_map.html.erb)

   Every shape carries both variants' fills as custom properties, and this is
   the same html[data-internals] switch the rest of the toggle uses, so the
   geometry is sent once. Outlines are <use> clones of each clip's path and
   inherit fill and stroke from .map-outline; vector-effect doesn't inherit
   into a clone, so their width is in viewBox units and thins with the map. */
.map-shape {
  fill: var(--fill-excl);
  stroke: #ffffff;
  stroke-width: 0.5px;
  vector-effect: non-scaling-stroke;
}
html[data-internals="on"] .map-shape {
  fill: var(--fill-incl);
}
a[data-active] > .map-shape {
  stroke: #0f172a;
  stroke-width: 1.5px;
}
.map-outline {
  fill: none;
  stroke: #94a3b8;
  stroke-width: 0.75;
  pointer-events: none;
}
.map-highlight {
  fill: none;
  stroke: #0f172a;
  stroke-width: 2px;
  vector-effect: non-scaling-stroke;
  pointer-events: none;
}
```

- [ ] **Step 4: Stimulus controller**

`app/javascript/controllers/map_chart_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { createTooltip } from "charts/tooltip"
import { partyColor } from "charts/theme"

// Interactivity for the server-rendered maps (races/_map.html.erb). Every
// word arrives in the map's tips JSON. This controller only works out which
// shape the pointer or keyboard means and places the readout there (the
// payload carries the words, the JS carries the geometry).
//
// A district can be a pixel wide on the national House map, so when the
// pointer isn't directly over a shape it snaps to the nearest shape center
// within SNAP_PX — for the same reason the histogram hit-tests by slot.
const SNAP_PX = 24

export default class extends Controller {
  static targets = ["shape", "tips"]

  connect() {
    this.svg = this.element.querySelector("svg")
    if (!this.svg || this.shapeTargets.length === 0 || !this.hasTipsTarget) return

    this.tips = JSON.parse(this.tipsTarget.textContent)
    this.tooltip = createTooltip(this.element)
    this.activeIndex = null

    this.onPointer = (event) => this.showAtPointer(event)
    this.onPointerLeave = (event) => {
      // A touch pointer "leaves" as the finger lifts; the tap that follows
      // opens the race, so only a mouse clears on leave.
      if (event.pointerType === "mouse") this.clear()
    }
    this.onKeydown = (event) => this.handleKeydown(event)
    this.onFocus = () => {
      if (this.activeIndex === null) this.show(0)
    }
    this.onBlur = () => this.clear()
    this.onVariantChange = () => {
      if (this.activeIndex !== null) this.render(this.activeIndex)
    }

    this.svg.addEventListener("pointermove", this.onPointer)
    this.svg.addEventListener("pointerleave", this.onPointerLeave)
    this.element.addEventListener("keydown", this.onKeydown)
    this.element.addEventListener("focus", this.onFocus)
    this.element.addEventListener("blur", this.onBlur)
    window.addEventListener("internals:changed", this.onVariantChange)
  }

  disconnect() {
    if (!this.tooltip) return // connect bailed: a map with nothing to hover

    this.clear() // so Turbo's page-cache snapshot has no highlighted shape
    this.svg.removeEventListener("pointermove", this.onPointer)
    this.svg.removeEventListener("pointerleave", this.onPointerLeave)
    this.element.removeEventListener("keydown", this.onKeydown)
    this.element.removeEventListener("focus", this.onFocus)
    this.element.removeEventListener("blur", this.onBlur)
    window.removeEventListener("internals:changed", this.onVariantChange)
    this.tooltip.destroy()
    this.tooltip = null
  }

  showAtPointer(event) {
    const direct = event.target.closest("[data-map-chart-target~='shape']")
    const index = direct ? this.shapeTargets.indexOf(direct) : this.nearestIndex(event.clientX, event.clientY)
    if (index === null || index < 0) {
      if (event.pointerType === "mouse") this.clear()
      return
    }
    this.show(index)
  }

  nearestIndex(clientX, clientY) {
    const matrix = this.svg.getScreenCTM()
    if (!matrix) return null

    let best = null
    let bestDistance = SNAP_PX
    this.shapeTargets.forEach((shape, index) => {
      const point = screenPoint(shape, matrix)
      const distance = Math.hypot(point.x - clientX, point.y - clientY)
      if (distance < bestDistance) {
        best = index
        bestDistance = distance
      }
    })
    return best
  }

  show(index) {
    if (index === this.activeIndex) return

    this.unhighlight()
    this.activeIndex = index
    this.shapeTargets[index].setAttribute("data-active", "")
    this.render(index)
  }

  render(index) {
    const shape = this.shapeTargets[index]
    const variant = document.documentElement.dataset.internals === "on" ? "incl_internals" : "excl_internals"
    const tip = this.tips[shape.dataset.key]?.[variant]
    const matrix = this.svg.getScreenCTM()
    if (!tip || !matrix) return

    const point = screenPoint(shape, matrix)
    const box = this.element.getBoundingClientRect()
    this.tooltip.show(point.x - box.left, point.y - box.top, {
      header: tip.header,
      subheader: tip.subheader,
      rows: tip.rows.map((row) => ({
        key: row.swatch ? partyColor(row.party) : null,
        value: row.value,
        valueColor: row.party ? partyColor(row.party) : null,
        label: row.label
      })),
      footer: tip.footer
    })
  }

  handleKeydown(event) {
    if (event.altKey || event.ctrlKey || event.metaKey) return // Alt+Left is the browser's Back

    const last = this.shapeTargets.length - 1
    const from = this.activeIndex ?? 0
    switch (event.key) {
      case "ArrowLeft": this.show(Math.max(0, from - 1)); break
      case "ArrowRight": this.show(Math.min(last, from + 1)); break
      case "Home": this.show(0); break
      case "End": this.show(last); break
      case "Enter":
        if (this.activeIndex === null) return
        Turbo.visit(this.shapeTargets[this.activeIndex].getAttribute("href"))
        break
      case "Escape": this.clear(); return
      default: return
    }
    event.preventDefault() // arrows/Home/End scroll the page otherwise
  }

  unhighlight() {
    if (this.activeIndex === null) return
    this.shapeTargets[this.activeIndex].removeAttribute("data-active")
  }

  clear() {
    this.unhighlight()
    this.activeIndex = null
    this.tooltip?.hide()
  }
}

// A shape's center (viewBox units, from data-cx/-cy) in client pixels.
function screenPoint(shape, matrix) {
  const x = parseFloat(shape.dataset.cx)
  const y = parseFloat(shape.dataset.cy)
  return { x: matrix.a * x + matrix.c * y + matrix.e, y: matrix.b * x + matrix.d * y + matrix.f }
}
```

- [ ] **Step 5: Wire /senate and /house**

In `app/views/races/senate.html.erb`, insert this block between the chamber-card `<% end %>` (the one closing `<% if @latest_run %> … <% else %> … <% end %>`) and the comment above `<div class="mt-10" data-controller="table-filter">`:

```erb
<%# The map is its own fragment: keyed on the run its colors come from, the
    boundaries it is drawn from (so seeding them shows the map without
    waiting for the next run), and the Senate race collection. The builder
    runs inside the block so a hit skips its queries; it returns nil until
    boundaries exist, and then this renders nothing. %>
<% cache [ "senate-map", @latest_run, Site::CacheKey.collection_freshness(Boundary.all), Site::CacheKey.collection_freshness(Race.senate) ] do %>
  <% senate_map = Site::Maps::SenateMap.build %>
  <% if senate_map %>
    <section class="mt-8" data-testid="senate-map-section">
      <%= render "races/map", payload: senate_map %>
    </section>
  <% end %>
<% end %>
```

In `app/views/races/house.html.erb`, insert the same block in the same position (after the chamber card's `<% end %>`, before the comment above the table's `<div class="mt-10" data-controller="table-filter">`), with `house-map`, `Race.house`, `Site::Maps::HouseMap.build`, and `data-testid="house-map-section"`.

Run: `bin/rails test test/controllers/races_controller_test.rb`
Expected: PASS, including the existing "house table query count does not scale with the number of districts".

- [ ] **Step 6: System test**

Append to `test/system/chart_interactions_test.rb`, inside the class:

```ruby
  test "senate map: hovering a state reads out its race, and the internals toggle recolors it" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "FL", box: [ -87.6, 24.5, -80.0, 31.0 ])
    Forecast.create!(model_run: model_runs(:model_run_one), race: races(:senate_maine), variant: :incl_internals,
                     p_dem_win: 0.2, p_rep_win: 0.8, p_other_win: 0.0, mean_margin: -6.0)

    visit senate_path

    within "[data-testid=map-senate]" do
      find("a[data-key='ME'] path").hover
      assert_selector "[data-testid=chart-tooltip]", text: "Maine Senate"
      assert_selector "[data-testid=chart-tooltip]", text: "62%"
    end

    fill = "getComputedStyle(document.querySelector(\"[data-testid=map-senate] a[data-key='ME'] path\")).fill"
    published = evaluate_script(fill)
    find("[data-testid=internals-toggle]").click
    assert_selector "html[data-internals='on']", visible: :all
    assert_not_equal published, evaluate_script(fill)
  end
```

Run: `bin/rails tailwindcss:build && bin/rails test:system`
Expected: PASS

- [ ] **Step 7: Full check, commit**

Run: `bin/rails test && bin/rubocop && bin/brakeman --no-pager`
Expected: all pass, no offenses, no warnings.

```bash
git add app/views/races/_map.html.erb app/views/races/_map_legend.html.erb app/helpers/maps_helper.rb \
  app/javascript/controllers/map_chart_controller.js app/assets/tailwind/application.css \
  app/views/races/senate.html.erb app/views/races/house.html.erb \
  test/controllers/races_controller_test.rb test/system/chart_interactions_test.rb
git commit -m "Draw the Senate and House maps on their chamber pages, with hover and keyboard readouts."
```

---

### Task 5: Race pages, dashboard, methodology (wave 4, Grok)

**Files:**
- Modify: `app/views/races/show.html.erb` (header map; `race-core` cache key)
- Modify: `app/views/home/_chamber_card.html.erb` (optional `map:` local), `app/views/home/index.html.erb` (pass `map: true`)
- Modify: `app/views/pages/methodology.html.erb` ("Where the data comes from")
- Test: `test/controllers/races_controller_test.rb`, `test/controllers/home_controller_test.rb`, `test/controllers/fragment_caching_test.rb`, `test/controllers/pages_controller_test.rb` (append to each)

**Interfaces:**
- Consumes:
  - `Site::Maps::SenateMap.build(highlight:)`, `Site::Maps::StateMap.build(race)`, `Site::Maps::HouseMap.build(key:, tolerance:)`, `Site::Maps::SenateMap.build(key:, tolerance:)`
  - `render "races/map", payload:, show_legend: false`
  - `Ingest::BoundarySync.congress_for`, `Ingest::Sources.cycle`
- Produces: nothing later tasks consume.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/races_controller_test.rb`:

```ruby
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
```

Append to `test/controllers/home_controller_test.rb`:

```ruby
  test "the dashboard's chamber cards carry small maps once boundaries exist, and /senate's card does not" do
    create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])
    create_boundary(state: "NY", box: [ -79.8, 40.5, -71.8, 45.0 ])
    create_boundary(state: "NY", district: 17, box: [ -74.2, 41.0, -73.5, 41.6 ])

    get root_path
    assert_select "[data-testid='chamber-card-map'] [data-testid='map-dashboard-senate']"
    assert_select "[data-testid='chamber-card-map'] [data-testid='map-dashboard-house']"

    get senate_path
    assert_select "[data-testid='chamber-card-map']", count: 0
  end
```

Append to `test/controllers/fragment_caching_test.rb`, inside the class:

```ruby
  test "seeding boundaries after a cached render shows the maps without a new model run" do
    with_fragment_caching do
      get senate_path
      get race_path(races(:senate_maine).slug)
      assert_select "[data-testid='race-map']", count: 0

      create_boundary(state: "ME", box: [ -71.1, 43.0, -66.9, 47.5 ])

      get senate_path
      assert_select "[data-testid='map-senate']"
      get race_path(races(:senate_maine).slug)
      assert_select "[data-testid='map-senate-locator']"
    end
  end
```

Append to `test/controllers/pages_controller_test.rb`:

```ruby
  test "methodology names the Census boundaries the maps are drawn from" do
    get methodology_path

    assert_select "[data-testid='map-sources']", text: /TIGERweb/
    assert_select "[data-testid='map-sources']", text: /#{Ingest::BoundarySync.congress_for(Ingest::Sources.cycle).ordinalize} Congress/
  end
```

Run: `bin/rails test test/controllers/races_controller_test.rb test/controllers/home_controller_test.rb test/controllers/fragment_caching_test.rb test/controllers/pages_controller_test.rb`
Expected: the new tests FAIL.

- [ ] **Step 2: Race page**

In `app/views/races/show.html.erb`, change the cache key line to:

```erb
<% cache [ "race-core", @race, @latest_run, @latest_dispatch, Site::CacheKey.collection_freshness(Boundary.all) ] do %>
```

Extend the comment above it: after "…this race's latest dispatch (@latest_dispatch…)", add "and the boundaries the header map is drawn from".

Inside the header's `<div class="flex flex-wrap items-start justify-between gap-4">`, after the first child `<div>…</div>` (name, badges, and candidate list) and before that flex container's closing `</div>`, insert:

```erb
    <%# A Senate race gets a locator; a House race gets its state's districts
        with its own outlined. Both return nil until boundaries are seeded. %>
    <% race_map = @race.house? ? Site::Maps::StateMap.build(@race) : Site::Maps::SenateMap.build(highlight: @race) %>
    <% if race_map %>
      <div class="w-full <%= @race.house? ? "sm:w-80 lg:w-96" : "sm:w-60" %>" data-testid="race-map">
        <%= render "races/map", payload: race_map, show_legend: false %>
      </div>
    <% end %>
```

- [ ] **Step 3: Dashboard chamber cards**

In `app/views/home/_chamber_card.html.erb`:

1. In the top comment's locals line, add `map (optional, default false: only the dashboard shows the card's map; /senate and /house already carry a full-size one)`.
2. Change the cache line to:

```erb
<% map = local_assigns.fetch(:map, false) %>
<% cache [ "chamber-card", chamber, model_run, map, (Site::CacheKey.collection_freshness(Boundary.all) if map) ] do %>
```

3. After the `<% end %>` that closes `<%= each_variant do |variant| %>`, and before `<% if house %>`, insert:

```erb
      <%# Outside each_variant: the map carries both variants' fills itself. %>
      <% if map %>
        <% chamber_map = house ? Site::Maps::HouseMap.build(key: "dashboard-house", tolerance: 1.0) : Site::Maps::SenateMap.build(key: "dashboard-senate", tolerance: 1.0) %>
        <% if chamber_map %>
          <div class="mt-4" data-testid="chamber-card-map">
            <%= render "races/map", payload: chamber_map, show_legend: false %>
          </div>
        <% end %>
      <% end %>
```

In `app/views/home/index.html.erb`, add `map: true` to both `render "home/chamber_card", …` calls.

- [ ] **Step 4: Methodology**

In `app/views/pages/methodology.html.erb`, inside the `data-sources` section, insert this paragraph after the Wikipedia one (before `</section>`):

```erb
  <p class="mt-3 text-slate-700" data-testid="map-sources">
    The maps are drawn from the U.S. Census Bureau&rsquo;s
    <a href="https://tigerweb.geo.census.gov/tigerwebmain/TIGERweb_main.html" class="underline decoration-slate-300 underline-offset-2 hover:decoration-slate-500">TIGERweb</a>
    boundaries: each state&rsquo;s shoreline-clipped outline, and the congressional districts of the
    <%= Ingest::BoundarySync.congress_for(Ingest::Sources.cycle).ordinalize %> Congress &mdash; the lines the states
    submitted for the <%= Ingest::Sources.cycle %> election, including those redrawn mid-decade. We fetch them once and
    draw every map ourselves.
  </p>
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test`
Expected: PASS. The fragment-reuse tests must still pass: a warm second request still runs fewer queries than the first.

- [ ] **Step 6: Full check, commit**

Run: `bin/rails tailwindcss:build && bin/rails test:system && bin/rubocop && bin/brakeman --no-pager`
Expected: all pass.

```bash
git add app/views/races/show.html.erb app/views/home/_chamber_card.html.erb app/views/home/index.html.erb \
  app/views/pages/methodology.html.erb test/controllers/races_controller_test.rb test/controllers/home_controller_test.rb \
  test/controllers/fragment_caching_test.rb test/controllers/pages_controller_test.rb
git commit -m "Put a locator or state map on each race page and small maps on the dashboard."
```

---

### Task 6: Integration and visual verification (orchestrator)

- [ ] **Step 1:** Run `bin/ci` on `district-maps`. Expected: green.
- [ ] **Step 2:** Seed real boundaries into development: `bin/rails pol:seed_races` if the dev board is empty, then `bin/rails pol:seed_boundaries`. Expected: 51 outlines, 435 districts.
- [ ] **Step 3:** Measure: render `/house` and check the `map-house` SVG's byte size. Target: under 200 KB raw for the SVG alone (the prototype measured about 173 KB at 0.5 px).
- [ ] **Step 4:** Browser check of `/`, `/senate`, `/house`, one Senate race, and one coastal House race (e.g. a Michigan or Maryland district), at 1280 px and 375 px:
  - hover readouts, including a tiny NYC district via snapping;
  - keyboard stepping;
  - the internals toggle recoloring;
  - no horizontal scroll at 375 px;
  - water clipped at the Great Lakes and the Chesapeake.
- [ ] **Step 5:** Fix anything found, re-run `bin/ci`, then offer the user the PR.
