require "net/http"
require "time"
require "yaml"
require "thread"

class ElectionNight::Collector
  MAX_BYTES = 150 * 1024 * 1024
  CIVIC_FAILURE_LIMIT = 4
  CIVIC_PROBE_INTERVAL = 180

  class SourceHTTPError < StandardError
    attr_reader :status

    def initialize(status)
      @status = status.to_i
      super("Source HTTP #{@status}")
    end
  end

  class CivicCircuitOpen < StandardError; end
  # Bump when adapter normalization or validation changes. Never reuse old
  # normalized geography after a parser fix, even when raw hashes match.
  NORMALIZATION_VERSION = 3
  ADAPTERS = {
    "enhanced_voting" => "ElectionNight::Sources::EnhancedVoting",
    "north_carolina" => "ElectionNight::Sources::NorthCarolina",
    "texas" => "ElectionNight::Sources::Texas",
    "iowa_ledger" => "ElectionNight::Sources::IowaLedger",
    "county_baseline" => "ElectionNight::Sources::CountyBaseline",
    "ohio" => "ElectionNight::Sources::Ohio",
    "florida" => "ElectionNight::Sources::Florida",
    "polling_desk" => "ElectionNight::Sources::PollingDesk",
    "california" => "ElectionNight::Sources::California",
    "washington" => "ElectionNight::Sources::Washington",
    "alaska_summary" => "ElectionNight::Sources::AlaskaSummary",
    "arkansas_tally" => "ElectionNight::Sources::ArkansasTally",
    "indiana" => "ElectionNight::Sources::Indiana",
    "nebraska" => "ElectionNight::Sources::Nebraska",
    "new_york_county" => "ElectionNight::Sources::NewYorkCounty",
    "clarity_county" => "ElectionNight::Sources::ClarityCounty",
    "maryland_house" => "ElectionNight::Sources::MarylandHouse",
    "civic_api" => "ElectionNight::Sources::CivicApi",
    "louisiana_senate" => "ElectionNight::Sources::LouisianaSenate",
    "st_charles" => "ElectionNight::Sources::StCharles"
  }.freeze

  def initialize(store: ElectionNight::Store.new, config: Rails.root.join("config/election_night_sources.yml"), now: nil)
    @store, @config, @now = store, config, now
  end

  def call
    # The breaker is local to this sweep. A later sweep probes again; cached
    # errors never increment the count or prevent those fresh probes.
    @civic_mutex = Mutex.new
    @civic_failures = 0
    @civic_open = false
    configuration = YAML.safe_load_file(@config)
    civic = configuration["civic_api"]
    primary = if civic
      ElectionNight::CivicCatalog.new(path: Rails.root.join(civic.fetch("catalog"))).sources(
        minimum_interval: civic.fetch("minimum_interval", 180), priority: civic.fetch("priority", 0))
    else
      []
    end
    fallback = configuration.fetch("sources", []).select { |s| s.fetch("enabled", true) }
    ids = (primary + fallback).map { |source| source.fetch("id") }
    raise "Duplicate source ID" unless ids.uniq.size == ids.size

    results = collect_parallel(primary, civic ? civic.fetch("concurrency", 2) : 1)
    fallback.each do |source|
      result = collect(source)
      # State exports contain tens of MB of precinct detail; only normalized
      # county rows survive. Release parser trees before loading the next one.
      GC.start(full_mark: true, immediate_sweep: true)
      results << result
    end
    results
  end

  private
    def now = @now || Time.current

    # Bound simultaneous requests to the shared provider. Large official
    # exports remain sequential so their parser trees cannot multiply memory.
    def collect_parallel(sources, concurrency)
      raise "Invalid collector concurrency" unless concurrency.is_a?(Integer) && concurrency.between?(1, 4)
      return [] if sources.empty?
      queue = Queue.new
      # Different races lead each time slot so a handful of broken endpoints
      # cannot indefinitely hide recovery elsewhere. Output stays catalog-ordered.
      sources.each_with_index.to_a.shuffle(random: Random.new(now.to_i / CIVIC_PROBE_INTERVAL)).each do |source, index|
        queue << [ source, index ]
      end
      results = Array.new(sources.size)
      Array.new([ concurrency, sources.size ].min) do
        Thread.new do
          loop do
            source, index = queue.pop(true)
            results[index] = collect(source)
          rescue ThreadError
            break
          end
        end
      end.each(&:value)
      GC.start(full_mark: true, immediate_sweep: true)
      results
    end

    def collect(source)
      attempted_at = now
      id = source.fetch("id")
      raise "Invalid source ID" unless id.match?(/\A[a-z0-9_\-]+\z/)
      previous = @store.read("sources/#{id}")
      previous = nil unless previous && previous["normalization_version"] == NORMALIZATION_VERSION
      interval = [ source.fetch("minimum_interval", 180).to_i, 120 ].max
      if previous && !civic_circuit_open?(source) && attempted_at - Time.iso8601(previous.fetch("attempted_at")) < interval
        # Source selection policy may change without changing parsed votes.
        return freshness(previous.merge(source.slice("priority", "source_role", "coverage_note")))
      end
      result = source.slice("id", "state", "label", "url", "expected_counties", "baseline_url", "baseline_note", "coverage_note", "source_kind", "upstream_url", "expected_races", "aggregate_only", "priority", "source_role").merge("attempted_at" => attempted_at.iso8601, "normalization_version" => NORMALIZATION_VERSION)
      result["url"] = source["page_url"] if source["page_url"]
      begin
        raise CivicCircuitOpen if civic_circuit_open?(source)
        version_body = nil
        version = if source["version_url"]
          version_body = download_for(source, source.fetch("version_url"))
          result["version_hash"] = @store.archive("#{id}-version", version_body)
          value = source["version_path"] ? JSON.parse(version_body).dig(*source.fetch("version_path")) : version_body.strip
          raise "Invalid source version token" unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]{1,80}\z/)
          value
        end
        resolved_url = resolve_version(source.fetch("url"), version)
        result["download_url"] = resolved_url
        result["url"] = resolved_url unless source["page_url"]
        body = download_for(source, resolved_url)
        result["raw_hash"] = @store.archive(id, body)
        adapter = ADAPTERS.fetch(source.fetch("adapter")).constantize.new(state: source.fetch("state"))
        parsed = if source["metadata_url"]
          metadata_url = resolve_version(source["metadata_url"], version)
          metadata = source["metadata_url"] == source["version_url"] ? version_body : download_for(source, metadata_url)
          result["metadata_hash"] = @store.archive("#{id}-metadata", metadata)
          adapter.parse(body, metadata: metadata)
        else
          adapter.parse(body)
        end
        raise "Feed is test data" if parsed["test"]
        raise "Wrong election date" unless parsed["election_date"] == "2026-11-03"
        if source["expected_races"]
          keys = (parsed.fetch("units") + Array(parsed["aggregate_units"])).map { |u| u.fetch("race_key") }.uniq.sort
          raise "Unexpected race identity" unless keys == source.fetch("expected_races").sort
        end
        counties = parsed.fetch("units").reject { |u| u["aggregate_only"] || (u["geography_level"] && u["geography_level"] != "county") }
        if source["expected_counties"] && counties.map { |u| u.fetch("unit_key") }.uniq.size != source["expected_counties"]
          raise "Incomplete statewide geography"
        end
        result.merge!("results" => parsed, "fetched_at" => now.iso8601,
          "published_at" => parsed["published_at"], "status" => "ok", "usable" => true)
        body = nil
        GC.start(full_mark: true, immediate_sweep: true)
        if previous && previous["baseline"]
          result.merge!(previous.slice("baseline", "baseline_hash"))
        end
        if source["baseline_url"] && !result["baseline"]
          begin
            historical = download(source["baseline_url"])
            result["baseline_hash"] = @store.archive("#{id}-baseline", historical)
            baseline_adapter = source["baseline_adapter"] ? ADAPTERS.fetch(source["baseline_adapter"]).constantize.new(state: source.fetch("state")) : adapter
            result["baseline"] = baseline_adapter.parse_baselines(historical)
          rescue StandardError => error
            result["baseline_error"] = "Historical baseline unavailable (#{error.class.name})"
          end
        end
      rescue StandardError => error
        Rails.logger.warn("ElectionNight source=#{id}: #{error.class.name}: #{error.message.to_s.truncate(300)}") unless error.is_a?(CivicCircuitOpen)
        result.merge!("status" => "error", "usable" => false,
          "error" => "Results unavailable or failed validation (#{error.class.name})")
        if error.is_a?(CivicCircuitOpen)
          result["error"] = "CivicAPI collection deferred after repeated provider failures; retrying on a later sweep"
          result["collection_skipped"] = "provider_circuit_open"
        end
        # Known counted votes do not cease to exist on a transient HTTP error.
        # Retain that exact version with its original timestamp and stale flag.
        result["last_good_at"] = previous && (previous["fetched_at"] || previous["last_good_at"])
        if previous && previous["results"]
          result.merge!(previous.slice("results", "baseline", "baseline_hash", "raw_hash", "metadata_hash", "version_hash", "download_url", "fetched_at", "published_at"))
          result["url"] = previous["url"] if !source["page_url"] && previous["url"]
          result["usable"] = true
        end
      end
      @store.write("sources/#{id}", result)
      freshness(result)
    end

    def freshness(result)
      result = result.deep_dup
      if result["fetched_at"] && now - Time.iso8601(result["fetched_at"]) > 15.minutes
        result["status"] = "stale"
      end
      result["report_age_seconds"] = [ now - Time.iso8601(result["published_at"]), 0 ].max.to_i if result["published_at"]
      result
    end

    def resolve_version(url, version)
      raise "Source version is required" if url.include?("{version}") && !version
      url.gsub("{version}", version.to_s)
    end

    def civic_circuit_open?(source)
      source["adapter"] == "civic_api" && @civic_mutex.synchronize { @civic_open }
    end

    def download_for(source, url)
      return download(url) unless source["adapter"] == "civic_api"
      raise CivicCircuitOpen if civic_circuit_open?(source)

      begin
        body = download(url)
      rescue StandardError => error
        @civic_mutex.synchronize do
          if civic_provider_failure?(error)
            @civic_failures += 1
            @civic_open = true if @civic_failures >= CIVIC_FAILURE_LIMIT
          else
            # A per-race HTTP error still demonstrates a responsive provider.
            @civic_failures = 0
          end
        end
        raise
      end
      # Count transport results, not adapter validation or cached source status.
      # Once open, the latch stays open until the next sweep despite late replies.
      @civic_mutex.synchronize { @civic_failures = 0 }
      body
    end

    def civic_provider_failure?(error)
      return error.status == 429 || error.status.between?(500, 599) if error.is_a?(SourceHTTPError)
      error.is_a?(Timeout::Error) || error.is_a?(SocketError) || error.is_a?(SystemCallError) ||
        error.is_a?(EOFError) || error.is_a?(IOError) || error.is_a?(OpenSSL::SSL::SSLError)
    end

    def download(url)
      uri = URI(url)
      raise "Source requires HTTPS" unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil?
      body = +"".b
      civic = uri.host == "civicapi.org"
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: civic ? 5 : 15, read_timeout: civic ? 10 : 45) do |http|
        http.max_retries = 0 if civic
        request = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => "535-election-results/1.0", "Accept" => "application/json,text/plain,*/*")
        http.request(request) do |response|
          raise SourceHTTPError, response.code unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            body << chunk
            raise "Source exceeds size limit" if body.bytesize > MAX_BYTES
          end
        end
      end
      body
    end
end
