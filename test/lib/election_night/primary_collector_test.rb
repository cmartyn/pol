require "test_helper"
require "tmpdir"
require "timeout"

class ElectionNight::PrimaryCollectorTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @config = File.join(@dir, "sources.yml")
    @store = ElectionNight::Store.new(root: @dir)
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "primary collection bounds concurrent requests and retains deterministic source order" do
    File.write(@config, { "civic_api" => { "catalog" => "unused.json", "concurrency" => 2 },
      "sources" => [ { "id" => "official" } ] }.to_yaml)
    catalog = Object.new
    catalog.define_singleton_method(:sources) { |**| %w[a b c].map { |id| { "id" => id } } }
    entered, release = Queue.new, Queue.new
    collector = ElectionNight::Collector.new(store: @store, config: @config)
    collector.define_singleton_method(:collect) do |source|
      unless source["id"] == "official"
        entered << source["id"]
        release.pop
      end
      source
    end
    result = stubbing(ElectionNight::CivicCatalog, :new, catalog) do
      worker = Thread.new { collector.call }
      Timeout.timeout(5) { 2.times { entered.pop } }
      assert entered.empty?, "a third request must not start while both workers are occupied"
      3.times { release << true }
      Timeout.timeout(5) { worker.value }
    ensure
      3.times { release << true }
      worker&.join(5)
    end
    assert_equal %w[a b c official], result.map { |source| source["id"] }
  end

  test "cached validated votes immediately adopt a changed source priority" do
    stamp = Time.iso8601("2026-11-03T21:00:00Z")
    @store.write("sources/probe", { "id" => "probe", "priority" => 10, "usable" => true,
      "status" => "ok", "normalization_version" => ElectionNight::Collector::NORMALIZATION_VERSION,
      "attempted_at" => stamp.iso8601, "fetched_at" => stamp.iso8601, "raw_hash" => "unchanged" })
    File.write(@config, { "sources" => [ { "id" => "probe", "priority" => 0 } ] }.to_yaml)
    result = ElectionNight::Collector.new(store: @store, config: @config, now: stamp).call.first
    assert_equal 0, result["priority"]
    assert_equal "unchanged", result["raw_hash"]
  end
end
