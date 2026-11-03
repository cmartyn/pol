require "minitest/autorun"
require "tmpdir"
require "stringio"

module ElectionNight
  module Sources
  end
end

%w[sources/base sources/civic_api store collector civic_catalog civic_validator].each do |file|
  require_relative "../../../app/lib/election_night/#{file}"
end

class ElectionNightCivicCatalogTest < Minitest::Test
  def test_complete_pinned_catalog_and_collector_configuration
    catalog = ElectionNight::CivicCatalog.new
    sources = catalog.sources(minimum_interval: 300, priority: 2)
    assert_equal 470, sources.size
    assert_equal 470, sources.map { |source| source["url"] }.uniq.size
    assert_equal 435, catalog.races.count { |race| race["chamber"] == "house" }
    assert_equal 35, catalog.races.count { |race| race["chamber"] == "senate" }
    assert sources.all? { |source| source["priority"] == 2 && source["minimum_interval"] == 300 }
    assert sources.all? { |source| source["source_role"] == "primary" }
    assert_equal [ "AK-AL" ], sources.find { |source| source["id"] == "civic_ak_al" }["expected_races"]
  end

  def test_duplicate_ids_changed_states_or_unapproved_hosts_are_rejected
    [ ->(data) { data["races"][0]["id"] = data["races"][1]["id"] },
      ->(data) { data["races"][0]["url"] = "https://example.com/api/v2/race/1" },
      ->(data) { data["races"].find { |r| r["race_key"] == "AK-S" }.merge!("race_key" => "AZ-S", "state" => "AZ") },
      ->(data) { data["races"][0]["race_key"] = "AK-01" },
      ->(data) { data["election_date"] = "2024-11-05" } ].each do |mutate|
      Dir.mktmpdir do |dir|
        data = JSON.parse(File.read(ElectionNight::CivicCatalog::DEFAULT_PATH))
        mutate.call(data)
        path = File.join(dir, "catalog.json")
        File.write(path, JSON.generate(data))
        assert_raises(ArgumentError) { ElectionNight::CivicCatalog.new(path: path) }
      end
    end
  end

  def source
    ElectionNight::CivicCatalog.new.sources.find { |s| s["id"] == "civic_al_02" }
  end

  def fixture
    File.binread(File.expand_path("../../fixtures/files/election_night/northeast/civic_al_house.json", __dir__))
  end

  def catalog
    source = self.source
    Struct.new(:sources, :data, :sha256).new([ source ], { "election_date" => "2026-11-03" }, "catalog-hash")
  end

  def validate(store, **options)
    ElectionNight::CivicValidator.new(store: store, catalog: catalog, delay: 0,
      sleeper: ->(_) { }, output: StringIO.new, **options).call
  end

  def test_transient_http_error_is_archived_and_retried_before_validation
    Dir.mktmpdir do |dir|
      store = ElectionNight::Store.new(root: dir)
      replies = [ { "status" => "503", "body" => "temporarily unavailable" }, { "status" => "200", "body" => fixture } ]
      report = validate(store, fetcher: ->(_) { replies.shift })
      assert_equal 1, report["validated"]
      record = store.read("sources/civic_al_02")
      assert_equal ElectionNight::Collector::NORMALIZATION_VERSION, record["normalization_version"]
      assert_equal 0, record["priority"]
      assert_equal [ "AL-02" ], record["expected_races"]
      attempts = store.read("validation/civic_al_02")["attempts"]
      assert_equal [ "503", "200" ], attempts.map { |attempt| attempt["http_status"] }
      attempts.each do |attempt|
        path = store.root.join("raw/civic_al_02", attempt.fetch("raw_hash"))
        assert_equal attempt["raw_hash"], Digest::SHA256.file(path).hexdigest
      end
      assert_equal 16, report["county_units"]
      refute report.to_s.include?("percent_reporting")
    end
  end

  def test_resume_reparses_archive_and_preserves_original_fetch_time
    Dir.mktmpdir do |dir|
      store = ElectionNight::Store.new(root: dir)
      validate(store, fetcher: ->(_) { { "status" => "200", "body" => fixture } })
      previous = store.read("sources/civic_al_02")
      previous["fetched_at"] = "2026-11-03T12:00:00Z"
      previous["results"]["aggregate_units"][0]["total_votes"] = 999_999
      store.write("sources/civic_al_02", previous)
      report = validate(store, fetcher: ->(_) { flunk "Archive should be reused without network" })
      assert_equal 1, report["reused_archives"]
      assert_equal "2026-11-03T12:00:00Z", store.read("sources/civic_al_02")["fetched_at"]
      assert_equal 0, report["sources"][0]["raw_total_votes"], "reparse bytes instead of trusting normalized cache"
      history = store.read("validation/civic_al_02")["runs"]
      assert_equal 2, history.size
      assert_equal "200", history.first["attempts"].first["http_status"], "resume retains the network audit"
    end
  end

  def test_test_payload_is_rejected_and_kept_for_audit
    Dir.mktmpdir do |dir|
      store = ElectionNight::Store.new(root: dir)
      body = JSON.generate(JSON.parse(fixture).merge("test_data" => true))
      report = validate(store, fetcher: ->(_) { { "status" => "200", "body" => body } })
      assert_equal 1, report["failed"]
      record = store.read("sources/civic_al_02")
      refute record["usable"]
      assert_match(/test flag/, record["error"])
      assert store.root.join("raw/civic_al_02", record["raw_hash"]).file?
    end
  end

  def test_permanent_http_error_does_not_retry_or_claim_counts
    Dir.mktmpdir do |dir|
      store = ElectionNight::Store.new(root: dir)
      calls = 0
      report = validate(store, fetcher: ->(_) { calls += 1; { "status" => "403", "body" => "Forbidden" } })
      assert_equal 1, calls
      assert_equal 1, report["failed"]
      refute store.read("sources/civic_al_02").key?("results")
    end
  end

  def test_wrong_race_response_and_corrupt_cached_bytes_are_not_accepted
    Dir.mktmpdir do |dir|
      store = ElectionNight::Store.new(root: dir)
      body = JSON.generate(JSON.parse(fixture).merge("district" => "AL-03"))
      report = validate(store, fetcher: ->(_) { { "status" => "200", "body" => body } })
      assert_equal 1, report["failed"]
      assert_match(/differs from catalog/, report["sources"][0]["error"])
      validate(store, fetcher: ->(_) { { "status" => "200", "body" => fixture } })
      hash = store.read("sources/civic_al_02")["raw_hash"]
      File.write(store.root.join("raw/civic_al_02", hash), "corrupted archive")
      calls = 0
      report = validate(store, fetcher: ->(_) { calls += 1; { "status" => "200", "body" => fixture } })
      assert_equal 1, calls, "corrupted cached bytes must not be reused"
      assert_equal 1, report["failed"]
      assert_match(/archive checksum mismatch/, report["sources"][0]["error"])
    end
  end
end
