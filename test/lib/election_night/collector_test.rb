require "test_helper"
require "tmpdir"

class ElectionNight::CollectorTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @store = ElectionNight::Store.new(root: @dir)
    @config = File.join(@dir, "sources.yml")
    @url = "https://example.test/results.json"
    File.write(@config, { "sources" => [ { "id" => "probe", "state" => "NC", "label" => "Probe",
      "adapter" => "enhanced_voting", "url" => @url, "minimum_interval" => 120 } ] }.to_yaml)
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "failed fetch preserves published snapshot and rate limits retries" do
    @store.write("latest", { "generated_at" => "2026-11-03T20:00:00Z" })
    stub_request(:get, @url).to_return(status: 503)
    now = Time.iso8601("2026-11-03T21:00:00Z")
    twice = 2.times.map { ElectionNight::Collector.new(store: @store, config: @config, now: now).call.first }
    assert twice.all? { |s| s["status"] == "error" && !s["usable"] }
    assert_requested :get, @url, times: 1
    assert_equal "2026-11-03T20:00:00Z", @store.latest.fetch("generated_at")
  end

  test "raw snapshots deduplicate while retaining exact payload" do
    hash = @store.archive("probe", "payload")
    assert_equal hash, @store.archive("probe", "payload")
    assert_equal "payload", File.binread(File.join(@dir, "raw/probe", hash))
  end

  test "transient failure retains last known votes and their provenance" do
    old = { "id" => "probe", "state" => "NC", "attempted_at" => "2026-11-03T20:00:00Z",
      "normalization_version" => ElectionNight::Collector::NORMALIZATION_VERSION,
      "fetched_at" => "2026-11-03T20:00:00Z", "published_at" => "2026-11-03T19:59:00Z",
      "raw_hash" => "raw-version", "baseline_hash" => "baseline-version", "results" => { "units" => [ { "total_votes" => 100 } ] },
      "baseline" => { "units" => [] }, "usable" => true, "status" => "ok" }
    @store.write("sources/probe", old)
    stub_request(:get, @url).to_return(status: 503)
    result = ElectionNight::Collector.new(store: @store, config: @config, now: Time.iso8601("2026-11-03T20:05:00Z")).call.first
    assert_equal "error", result["status"]
    assert result["usable"]
    assert_equal old["results"], result["results"]
    assert_equal "baseline-version", result["baseline_hash"]
    assert_equal old["fetched_at"], result["fetched_at"]
  end

  test "concurrent writer is refused" do
    @store.locked do
      assert_raises(RuntimeError) { ElectionNight::Store.new(root: @dir).locked { flunk "second writer entered" } }
    end
  end

  test "incompatible cached geography is refetched and never retained after a failed validation" do
    now = Time.iso8601("2026-11-03T21:00:00Z")
    @store.write("sources/probe", { "id" => "probe", "attempted_at" => now.iso8601,
      "results" => { "units" => [ { "total_votes" => 100 } ] }, "usable" => true, "status" => "ok" })
    stub_request(:get, @url).to_return(status: 503)

    result = ElectionNight::Collector.new(store: @store, config: @config, now: now).call.first

    assert_requested :get, @url, times: 1
    assert_equal ElectionNight::Collector::NORMALIZATION_VERSION, result["normalization_version"]
    assert_not result["usable"]
    assert_nil result["results"]
  end
end
