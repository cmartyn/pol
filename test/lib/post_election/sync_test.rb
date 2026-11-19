require "test_helper"
require "tmpdir"

class PostElection::SyncTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    races(:senate_maine).update!(slug: ForecastArchive.races.keys.find { |slug| ForecastArchive.races[slug]["race_key"] == "ME-S" })
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "the failure names each race with its cause" do
    sources = [
      { "expected_races" => [ "MN-01" ], "status" => "error", "usable" => false,
        "error" => "Results unavailable or failed validation (ElectionNight::Collector::SourceHTTPError)" },
      { "expected_races" => [ "TX-28" ], "status" => "error", "usable" => false,
        "error" => "CivicAPI collection deferred", "collection_skipped" => "provider_circuit_open" },
      { "expected_races" => [ "AK-01" ], "status" => "stale", "usable" => true },
      { "expected_races" => [ "ME-S" ], "status" => "ok", "usable" => true, "id" => "civic_other", "raw_hash" => "0" * 64 }
    ]
    error = assert_raises(RuntimeError) do
      PostElection::Sync.new(store: ElectionNight::Store.new(root: @dir)).send(:import, sources)
    end
    assert_equal "Failed result sources: " \
      "MN-01: Results unavailable or failed validation (ElectionNight::Collector::SourceHTTPError); " \
      "TX-28: provider_circuit_open; AK-01: status stale; ME-S: ArgumentError: Unexpected archived source", error.message
  end
end
