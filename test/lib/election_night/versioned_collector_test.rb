require "test_helper"
require "tmpdir"

class ElectionNight::VersionedCollectorTest < ActiveSupport::TestCase
  class RecordingAdapter
    attr_reader :calls

    def initialize(result)
      @result, @calls = result, []
    end

    def parse(body, metadata: nil)
      @calls << { body: body, metadata: metadata }
      @result.deep_dup
    end
  end

  setup do
    @dir = Dir.mktmpdir
    @store = ElectionNight::Store.new(root: @dir)
    @config = File.join(@dir, "sources.yml")
    @now = Time.iso8601("2026-11-03T21:00:00Z")
    @version_url = "https://example.test/settings.json"
    @source = { "id" => "probe", "state" => "NC", "label" => "Probe", "adapter" => "enhanced_voting",
      "url" => "https://example.test/results_{version}.json", "minimum_interval" => 120 }
  end

  teardown { FileUtils.remove_entry(@dir) }

  def unit(key = "NC-S", name = "WAKE", **options)
    { "race_key" => key, "unit_key" => name, "dem_votes" => 60, "rep_votes" => 40,
      "other_votes" => 0, "total_votes" => 100, "complete" => false }.merge(options.transform_keys(&:to_s))
  end

  def result(units = [ unit ], aggregate_units: [])
    { "election_date" => "2026-11-03", "test" => false, "published_at" => "2026-11-03T20:59:00Z",
      "units" => units, "aggregate_units" => aggregate_units }
  end

  def collect(source = @source, normalized: result, now: @now)
    File.write(@config, { "sources" => [ source ] }.to_yaml)
    adapter = RecordingAdapter.new(normalized)
    collected = stubbing(ElectionNight::Sources::EnhancedVoting, :new, adapter) do
      ElectionNight::Collector.new(store: @store, config: @config, now: now).call.first
    end
    [ collected, adapter ]
  end

  test "JSON version path resolves data and reuses identical settings metadata bytes" do
    settings = '{"Root":{"VersionType":"B","CurrentElection":"11/03/2026"}}'
    @source.merge!("version_url" => @version_url, "version_path" => [ "Root", "VersionType" ], "metadata_url" => @version_url)
    stub_request(:get, @version_url).to_return(body: settings)
    resolved = "https://example.test/results_B.json"
    stub_request(:get, resolved).to_return(body: "results B")

    collected, adapter = collect

    assert collected["usable"]
    assert_equal "ok", collected["status"]
    assert_equal resolved, collected["url"]
    assert_equal resolved, collected["download_url"]
    assert_equal [ { body: "results B", metadata: settings } ], adapter.calls
    assert_requested :get, @version_url, times: 1
    assert_requested :get, resolved, times: 1
    assert_equal collected["version_hash"], collected["metadata_hash"]
    assert_equal settings, File.binread(File.join(@dir, "raw/probe-version", collected["version_hash"]))
    assert_equal settings, File.binread(File.join(@dir, "raw/probe-metadata", collected["metadata_hash"]))
  end

  test "plaintext version resolves both result and distinct metadata URLs while preserving public page URL" do
    @source.merge!("version_url" => @version_url, "metadata_url" => "https://example.test/metadata_{version}.json", "page_url" => "https://example.test/public")
    stub_request(:get, @version_url).to_return(body: "release_12-AB\n")
    stub_request(:get, "https://example.test/results_release_12-AB.json").to_return(body: "results")
    stub_request(:get, "https://example.test/metadata_release_12-AB.json").to_return(body: "metadata")

    collected, adapter = collect

    assert collected["usable"]
    assert_equal "https://example.test/public", collected["url"]
    assert_equal "https://example.test/results_release_12-AB.json", collected["download_url"]
    assert_equal [ { body: "results", metadata: "metadata" } ], adapter.calls
    assert_requested :get, "https://example.test/metadata_release_12-AB.json", times: 1
  end

  test "rate limited versioned source advances to the next version only after its fetch interval" do
    @source.merge!("version_url" => @version_url, "version_path" => [ "Root", "VersionType" ], "metadata_url" => @version_url)
    stub_request(:get, @version_url).to_return(body: '{"Root":{"VersionType":"B"}}').then.to_return(body: '{"Root":{"VersionType":"A"}}')
    stub_request(:get, "https://example.test/results_B.json").to_return(body: "B")
    stub_request(:get, "https://example.test/results_A.json").to_return(body: "A")

    first, = collect
    cached, cached_adapter = collect(now: @now + 119)
    refreshed, refreshed_adapter = collect(now: @now + 120)

    assert_equal first["raw_hash"], cached["raw_hash"]
    assert_empty cached_adapter.calls
    assert_equal "https://example.test/results_A.json", refreshed["download_url"]
    assert_equal "A", refreshed_adapter.calls.first[:body]
    assert_requested :get, @version_url, times: 2
    assert_requested :get, "https://example.test/results_B.json", times: 1
    assert_requested :get, "https://example.test/results_A.json", times: 1
  end

  test "failed new version retains the old counts hashes and resolved provenance links" do
    @source.merge!("version_url" => @version_url, "version_path" => [ "Root", "VersionType" ], "metadata_url" => @version_url)
    stub_request(:get, @version_url).to_return(body: '{"Root":{"VersionType":"B"}}').then.to_return(body: '{"Root":{"VersionType":"A"}}')
    stub_request(:get, "https://example.test/results_B.json").to_return(body: "B")
    stub_request(:get, "https://example.test/results_A.json").to_return(status: 503)

    first, = collect
    retained, adapter = collect(now: @now + 120)

    assert retained["usable"]
    assert_equal "error", retained["status"]
    assert_empty adapter.calls
    assert_equal first["results"], retained["results"]
    assert_equal first.slice("raw_hash", "metadata_hash", "version_hash", "fetched_at", "published_at", "download_url", "url"),
      retained.slice("raw_hash", "metadata_hash", "version_hash", "fetched_at", "published_at", "download_url", "url")
  end

  test "unsafe version tokens are rejected before requesting results or invoking an adapter" do
    [ "../A", "%2e%2e%2fA", "A?override=1", "https://other.test/A", "A" * 81 ].each_with_index do |version, index|
      url = "https://example.test/version_#{index}.json"
      source = @source.merge("id" => "unsafe_#{index}", "version_url" => url, "version_path" => [ "version" ])
      stub_request(:get, url).to_return(body: { "version" => version }.to_json)
      collected, adapter = collect(source)
      assert_equal "error", collected["status"]
      assert_not collected["usable"]
      assert_nil collected["download_url"]
      assert_empty adapter.calls
      assert_requested :get, url, times: 1
    end
    assert_not_requested :get, %r{https://example\.test/results_}
  end

  test "missing and nonstring JSON version values are rejected" do
    [ {}, { "version" => nil }, { "version" => 3 }, { "version" => [ "B" ] } ].each_with_index do |settings, index|
      url = "https://example.test/missing_#{index}.json"
      source = @source.merge("id" => "missing_#{index}", "version_url" => url, "version_path" => [ "version" ])
      stub_request(:get, url).to_return(body: settings.to_json)
      collected, adapter = collect(source)
      assert_not collected["usable"]
      assert_empty adapter.calls
    end
  end

  test "expected race identity includes separate aggregates without counting mirrored race twice" do
    source = @source.merge("url" => "https://example.test/direct.json", "expected_races" => %w[NC-01 NC-S])
    stub_request(:get, source["url"]).to_return(body: "data")
    counties = [ unit("NC-01", "WAKE"), unit("NC-01", "DURHAM") ]
    aggregates = [ unit("NC-01", "DISTRICT 01", aggregate_only: true), unit("NC-S", "STATEWIDE", aggregate_only: true) ]

    collected, = collect(source, normalized: result(counties, aggregate_units: aggregates))

    assert collected["usable"]
    assert_equal 2, collected.dig("results", "aggregate_units").size
  end

  test "expected race identity rejects missing and unexpected races" do
    [ [ unit("NC-01") ], [ unit("NC-01"), unit("NC-S"), unit("SC-S") ] ].each_with_index do |units, index|
      source = @source.merge("id" => "identity_#{index}", "url" => "https://example.test/direct_#{index}.json", "expected_races" => %w[NC-01 NC-S])
      stub_request(:get, source["url"]).to_return(body: "data")
      collected, = collect(source, normalized: result(units))
      assert_not collected["usable"]
      assert_equal "error", collected["status"]
      assert_nil collected["results"]
    end
  end

  test "expected county count ignores aggregate precinct and other explicit geographic levels" do
    source = @source.merge("url" => "https://example.test/direct.json", "expected_counties" => 2)
    stub_request(:get, source["url"]).to_return(body: "data")
    units = [ unit("NC-S", "WAKE"), unit("NC-S", "DURHAM", geography_level: "county"),
      unit("NC-S", "STATEWIDE", aggregate_only: true), unit("NC-01", "DISTRICT 01", geography_level: "contest"),
      unit("NC-S", "PRECINCT 1", geography_level: "precinct") ]

    collected, = collect(source, normalized: result(units))

    assert collected["usable"]
    assert_equal "ok", collected["status"]
  end

  test "aggregate or precinct row cannot fill a missing county" do
    [ { aggregate_only: true }, { geography_level: "contest" }, { geography_level: "precinct" } ].each_with_index do |options, index|
      source = @source.merge("id" => "county_#{index}", "url" => "https://example.test/county_#{index}.json", "expected_counties" => 2)
      stub_request(:get, source["url"]).to_return(body: "data")
      collected, = collect(source, normalized: result([ unit("NC-S", "WAKE"), unit("NC-S", "NOT A COUNTY", **options) ]))
      assert_not collected["usable"]
      assert_equal "error", collected["status"]
      assert_nil collected["results"]
    end
  end
end
