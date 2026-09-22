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
    # Braced hash: Ruby 4 treats a bare `"AK" => ...` as keywords and drops the positional arg.
    stub_tigerweb({ "AK" => { fips: "02", box: [ 172.0, 51.0, 179.0, 53.0 ], districts: %w[00] } })

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
