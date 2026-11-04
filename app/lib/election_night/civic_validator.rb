require "net/http"
require "time"
require "digest"

# A resumable, sequential audit. This intentionally avoids parallel requests to
# the public provider. Archived responses are reparsed, never blindly trusted.
class ElectionNight::CivicValidator
  MAX_BYTES = 12 * 1024 * 1024
  RETRY_CODES = %w[429 500 502 503 504].freeze
  HttpError = Class.new(StandardError)
  ArchiveError = Class.new(StandardError)

  def initialize(store:, catalog: ElectionNight::CivicCatalog.new, reuse_stores: [],
    delay: 0.25, retries: 3, fetcher: nil, sleeper: ->(seconds) { sleep(seconds) }, output: $stdout)
    @store, @catalog, @reuse_stores = store, catalog, reuse_stores
    @delay, @retries, @sleeper, @output = delay, retries, sleeper, output
    @fetcher = fetcher || method(:download)
  end

  def call
    @store.locked do
      started_at = Time.now.utc
      sources = @catalog.sources
      records = sources.map.with_index do |source, index|
        record = validate(source)
        @output.puts JSON.generate("progress" => index + 1, "total" => sources.size,
          "id" => source.fetch("id"), "status" => record.fetch("status"), "reused" => record["validation_reused"],
          "error" => record["error"])
        @output.flush
        record
      end
      report = {
        "election_date" => @catalog.data.fetch("election_date"), "catalog_sha256" => @catalog.sha256,
        "started_at" => started_at.iso8601, "completed_at" => Time.now.utc.iso8601,
        "elapsed_seconds" => (Time.now.utc - started_at).round(3), "races_total" => records.size,
        "validated" => records.count { |r| r["usable"] }, "failed" => records.count { |r| !r["usable"] },
        "reused_archives" => records.count { |r| r["validation_reused"] },
        "county_detail_races" => records.count { |r| r.dig("results", "units")&.any? },
        "county_units" => records.sum { |r| Array(r.dig("results", "units")).size },
        "scope_note" => "County detail is not independent proof of complete geography; zero sums alone cannot validate a county manifest.",
        "sources" => records.map do |r|
          r.slice("id", "state", "url", "expected_races", "status", "usable", "raw_hash", "fetched_at", "attempted_at", "published_at", "error", "validation_reused").merge(
            "county_units" => Array(r.dig("results", "units")).size,
            "county_detail_reason" => r.dig("results", "county_detail_reason"),
            "county_totals_match_aggregate" => r.dig("results", "county_totals_match_aggregate"),
            "raw_total_votes" => r["usable"] ? r.fetch("results").fetch("aggregate_units").sum { |u| u.fetch("total_votes") } : nil)
        end
      }
      @store.write("civic_validation", report)
    end
  end

  private
    def validate(source)
      id = source.fetch("id")
      record = source.slice("id", "state", "label", "url", "expected_races", "source_kind", "upstream_url", "coverage_note", "priority", "source_role").merge(
        "attempted_at" => Time.now.utc.iso8601, "normalization_version" => ElectionNight::Collector::NORMALIZATION_VERSION,
        "download_url" => source.fetch("url"), "status" => "error", "usable" => false)
      attempts = []
      reuse = reusable(source)
      if reuse
        body, previous = reuse
        record.merge!("raw_hash" => archive_response(id, body), "fetched_at" => previous.fetch("fetched_at"), "validation_reused" => true)
      else
        (@retries + 1).times do |attempt|
          @sleeper.call(@delay)
          attempted = { "attempt" => attempt + 1, "at" => Time.now.utc.iso8601 }
          begin
            response = @fetcher.call(source.fetch("url"))
            body = response.fetch("body")
            hash = archive_response(id, body)
            attempted.merge!("http_status" => response.fetch("status"), "raw_hash" => hash, "bytes" => body.bytesize)
            record["raw_hash"] = hash
            unless response.fetch("status") == "200"
              raise HttpError, "HTTP #{response.fetch('status')}"
            end
            record.merge!("fetched_at" => Time.now.utc.iso8601, "validation_reused" => false)
            attempts << attempted
            break
          rescue StandardError => error
            attempted["error"] = "#{error.class}: #{error.message.to_s[0, 300]}"
            attempts << attempted
            retryable = !error.is_a?(ArchiveError) && (!error.is_a?(HttpError) || RETRY_CODES.include?(attempted["http_status"]))
            raise unless retryable && attempt < @retries
            @sleeper.call([ 2**(attempt + 1), 30 ].min)
          end
        end
      end
      parsed = ElectionNight::Sources::CivicApi.new(state: source.fetch("state")).parse(body)
      keys = (parsed.fetch("units") + parsed.fetch("aggregate_units")).map { |u| u.fetch("race_key") }.uniq
      raise ArgumentError, "Full-race identity differs from catalog" unless keys == source.fetch("expected_races")
      record.merge!("results" => parsed, "published_at" => parsed["published_at"], "status" => "ok", "usable" => true)
      record
    rescue StandardError => error
      record.merge!("status" => "error", "usable" => false, "error" => "#{error.class}: #{error.message.to_s[0, 300]}")
    ensure
      if record
        previous = @store.read("validation/#{id}")
        history = previous ? (previous["runs"] || [ previous ]) : []
        run = { "validated_at" => record["attempted_at"], "attempts" => attempts, "reused" => record["validation_reused"] }
        @store.write("validation/#{id}", run.merge("runs" => history + [ run ]))
      end
      @store.write("sources/#{id}", record) if record
    end

    def reusable(source)
      ([ @store ] + @reuse_stores).each do |store|
        previous = store.read("sources/#{source.fetch('id')}")
        next unless previous && previous["usable"] && previous["url"] == source["url"] && previous["raw_hash"] && previous["fetched_at"]
        path = store.root.join("raw", source.fetch("id"), previous.fetch("raw_hash"))
        next unless path.file?
        body = path.binread
        next unless Digest::SHA256.hexdigest(body) == previous.fetch("raw_hash")
        return [ body, previous ]
      end
      nil
    end

    def archive_response(id, body)
      hash = @store.archive(id, body)
      path = @store.root.join("raw", id, hash)
      raise ArchiveError, "Stored archive checksum mismatch" unless Digest::SHA256.file(path).hexdigest == hash
      hash
    end

    def download(url)
      uri = URI(url)
      raise ArgumentError, "Unapproved Civic endpoint" unless uri.is_a?(URI::HTTPS) && uri.host == "civicapi.org" && uri.userinfo.nil? && uri.path.match?(/\A\/api\/v2\/race\/\d+\z/) && uri.query.nil?
      body = +"".b
      status = nil
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
        request = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => "535-election-results/1.0", "Accept" => "application/json")
        http.request(request) do |response|
          status = response.code
          response.read_body do |chunk|
            body << chunk
            raise ArgumentError, "Civic response exceeds size limit" if body.bytesize > MAX_BYTES
          end
        end
      end
      { "status" => status, "body" => body }
    end
end
