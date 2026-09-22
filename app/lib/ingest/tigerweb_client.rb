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
    # name. A name that isn't there, or that matches more than one data
    # layer, means the service changed shape — nothing should guess.
    LayerNotFound = Class.new(Error)

    BASE = "https://tigerweb.geo.census.gov/arcgis/rest/services/".freeze

    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 60
    ATTEMPTS = 3
    MIN_INTERVAL = 1.0
    BACKOFF_BASE = 0.5

    # ArcGIS label layers repeat their data layer's name (State_County's
    # "Labels" group has its own "States 500K", and queries against it fail),
    # so only layers outside that group count.
    LABELS_GROUP = "Labels".freeze

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
      layers = Array(get_json(URI("#{self.class.service_url(service)}?f=json"))["layers"])
      by_id = layers.index_by { |layer| layer["id"] }
      matches = layers.select do |layer|
        layer["name"] == layer_name && layer["type"] != "Group Layer" && !inside_labels?(layer, by_id)
      end
      raise LayerNotFound, "#{service} has no layer named #{layer_name.inspect}" if matches.empty?
      raise LayerNotFound, "#{service} has #{matches.size} layers named #{layer_name.inspect}" if matches.size > 1

      matches.first.fetch("id")
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
      def inside_labels?(layer, by_id)
        parent = by_id[layer["parentLayerId"]]
        while parent
          return true if parent["name"] == LABELS_GROUP

          parent = by_id[parent["parentLayerId"]]
        end
        false
      end

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
