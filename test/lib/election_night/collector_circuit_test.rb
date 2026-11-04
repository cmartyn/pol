require "test_helper"
require "tmpdir"

class ElectionNight::CollectorCircuitTest < ActiveSupport::TestCase
  CIVIC_URLS = %r{\Ahttps://civicapi\.org/api/v2/race/\d+\z}

  setup do
    @dir = Dir.mktmpdir
    @store = ElectionNight::Store.new(root: @dir)
    @config = File.join(@dir, "sources.yml")
    @now = Time.iso8601("2026-11-04T01:15:00Z")
    @body = file_fixture("election_night/northeast/civic_al_house.json").read
    @sources = Array.new(20) do |index|
      { "id" => "civic_probe_#{index}", "state" => "AL", "adapter" => "civic_api",
        "url" => "https://civicapi.org/api/v2/race/#{index + 1}", "minimum_interval" => 180 }
    end
  end

  teardown { FileUtils.remove_entry(@dir) }

  def collect(now: @now, concurrency: 1, fallback: [], collector: nil)
    File.write(@config, { "civic_api" => { "catalog" => "unused.json", "concurrency" => concurrency },
      "sources" => fallback }.to_yaml)
    catalog = Object.new
    sources = @sources
    catalog.define_singleton_method(:sources) { |**| sources }
    stubbing(ElectionNight::CivicCatalog, :new, catalog) do
      (collector || ElectionNight::Collector.new(store: @store, config: @config, now: now)).call
    end
  end

  test "shared provider failure bounds concurrent requests while keeping every source and proceeding to alternatives" do
    requests, mutex = [], Mutex.new
    stub_request(:get, CIVIC_URLS).to_return do |request|
      mutex.synchronize { requests << request.uri.to_s }
      { status: 503 }
    end
    fallback = { "id" => "official", "state" => "NC", "adapter" => "enhanced_voting",
      "url" => "https://official.test/results.json" }
    stub_request(:get, fallback["url"]).to_return(status: 404)

    result = collect(concurrency: 2, fallback: [ fallback ])

    assert_operator requests.size, :>=, ElectionNight::Collector::CIVIC_FAILURE_LIMIT
    assert_operator requests.size, :<=, ElectionNight::Collector::CIVIC_FAILURE_LIMIT + 1
    assert_equal @sources.map { |s| s["id"] } + [ "official" ], result.map { |s| s["id"] }
    assert result.all? { |source| source["status"] == "error" && !source["usable"] }
    assert_operator result.count { |source| source["collection_skipped"] == "provider_circuit_open" }, :>=, 15
    assert_requested :get, fallback["url"], times: 1
  end

  test "timeouts open the breaker and the next eligible sweep recovers" do
    stub_request(:get, CIVIC_URLS).to_raise(Net::ReadTimeout)
    failed = collect
    assert_equal 16, failed.count { |source| source["collection_skipped"] == "provider_circuit_open" }
    assert_requested :get, CIVIC_URLS, times: 4

    stub_request(:get, CIVIC_URLS).to_return(body: @body)
    recovered = collect(now: @now + 180)

    assert recovered.all? { |source| source["status"] == "ok" && source["usable"] }
    assert recovered.none? { |source| source["collection_skipped"] }
    assert_requested :get, CIVIC_URLS, times: 24
  end

  test "successful transport resets consecutive failures including rate limits" do
    @sources = @sources.first(8)
    responses = [ 503, 429, 502, 200, 503, 429, 502, 200 ]
    stub_request(:get, CIVIC_URLS).to_return { { status: responses.shift, body: @body } }

    result = collect

    assert_requested :get, CIVIC_URLS, times: 8
    assert_equal 2, result.count { |source| source["status"] == "ok" }
    assert result.none? { |source| source["collection_skipped"] }
  end

  test "per-race missing endpoints and schema failures do not trip the provider breaker" do
    statuses = [ 503, 503, 503, 404, 503, 503, 503, 200 ] * 3
    stub_request(:get, CIVIC_URLS).to_return { { status: statuses.shift, body: "{}" } }

    result = collect

    assert_requested :get, CIVIC_URLS, times: 20
    assert result.all? { |source| source["status"] == "error" }
    assert result.none? { |source| source["collection_skipped"] }
  end

  test "deferred sources retain the exact last successful counts hashes and timestamps" do
    old_time = (@now - 600).iso8601
    previous = { "normalization_version" => ElectionNight::Collector::NORMALIZATION_VERSION,
      "attempted_at" => old_time, "fetched_at" => old_time, "published_at" => (@now - 650).iso8601,
      "raw_hash" => "raw-version", "metadata_hash" => "metadata-version", "baseline_hash" => "baseline-version",
      "results" => { "units" => [ { "total_votes" => 1234 } ] }, "baseline" => { "units" => [] },
      "usable" => true, "status" => "ok" }
    @sources.each { |source| @store.write("sources/#{source['id']}", previous.merge("id" => source["id"])) }
    stub_request(:get, CIVIC_URLS).to_return(status: 503)

    result = collect
    deferred = result.select { |source| source["collection_skipped"] }

    assert_equal 16, deferred.size
    deferred.each do |source|
      assert source["usable"]
      assert_equal "error", source["status"]
      assert_equal previous.slice("results", "baseline", "raw_hash", "metadata_hash", "baseline_hash", "fetched_at", "published_at"),
        source.slice("results", "baseline", "raw_hash", "metadata_hash", "baseline_hash", "fetched_at", "published_at")
      assert_equal old_time, source["last_good_at"]
      assert_match(/deferred after repeated provider failures/, source["error"])
    end
  end

  test "cached errors do not increment the breaker or suppress fresh eligible requests" do
    @sources.first(12).each do |source|
      @store.write("sources/#{source['id']}", { "id" => source["id"], "attempted_at" => @now.iso8601,
        "normalization_version" => ElectionNight::Collector::NORMALIZATION_VERSION, "status" => "error", "usable" => false })
    end
    stub_request(:get, CIVIC_URLS).to_return(body: @body)

    result = collect

    assert_requested :get, CIVIC_URLS, times: 8
    assert_equal 8, result.count { |source| source["status"] == "ok" }
    assert result.none? { |source| source["collection_skipped"] }
  end

  test "probe order changes between time slots while output order remains stable" do
    requests = []
    stub_request(:get, CIVIC_URLS).to_return do |request|
      requests << request.uri.to_s
      { status: 503 }
    end

    first = collect
    first_requests = requests.dup
    requests.clear
    second = collect(now: @now + 180)

    assert_equal 4, first_requests.size
    assert_equal 4, requests.size
    assert_not_equal first_requests.sort, requests.sort
    assert_equal first.map { |source| source["id"] }, second.map { |source| source["id"] }
  end

  test "existing single argument download overrides remain compatible" do
    body = @body
    collector = ElectionNight::Collector.new(store: @store, config: @config, now: @now)
    collector.define_singleton_method(:download) { |_url| body }

    assert collect(collector: collector).all? { |source| source["status"] == "ok" }
  end

  test "Civic HTTP transport has shorter timeouts and no hidden retry" do
    http = Object.new
    retries = nil
    http.define_singleton_method(:max_retries=) { |value| retries = value }
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:read_body) { |&block| block.call("payload") }
    http.define_singleton_method(:request) { |_request, &block| block.call(response) }
    options = nil
    start = lambda do |*, **kwargs, &block|
      options = kwargs
      block.call(http)
    end
    collector = ElectionNight::Collector.new(store: @store, config: @config, now: @now)

    result = replacing(Net::HTTP, :start, start) do
      collector.send(:download, "https://civicapi.org/api/v2/race/1")
    end

    assert_equal "payload", result
    assert_equal 5, options[:open_timeout]
    assert_equal 10, options[:read_timeout]
    assert_equal 0, retries
  end
end
