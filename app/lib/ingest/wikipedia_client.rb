require "net/http"
require "uri"
require "erb"

module Ingest
  # Fetches a Wikipedia article as Parsoid HTML, politely.
  #
  #   Ingest::WikipediaClient.new.page_html("2026 United States elections")
  #
  # Wikimedia's API etiquette asks for a descriptive User-Agent with a contact
  # address and for clients not to hammer the servers, so every instance paces
  # itself to one request per MIN_INTERVAL seconds and identifies itself with
  # the contact address from config/model_params.yml.
  class WikipediaClient
    Error = Class.new(StandardError)
    # The page does not exist. Never retried — a 404 will still be a 404 in two
    # seconds — and callers are expected to treat it as "skip this source".
    NotFound = Class.new(Error)
    # Anything else that stopped us getting the HTML.
    FetchFailed = Class.new(Error)

    # The documented REST endpoint. As of August 2026 it answers 301 with a
    # same-host Location of /w/rest.php/v1/page/{title}/html, which #page_html
    # follows; keeping the documented URL here means a future move is absorbed
    # the same way.
    ENDPOINT = "https://en.wikipedia.org/api/rest_v1/page/html/".freeze
    ARTICLE_BASE = "https://en.wikipedia.org/wiki/".freeze

    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 15
    ATTEMPTS = 3
    REDIRECT_LIMIT = 3
    MIN_INTERVAL = 1.0
    BACKOFF_BASE = 0.5

    # Transport-level failures worth another try.
    RETRIABLE_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH, EOFError, SocketError
    ].freeze

    # The human-readable article URL for a title — what we store as a poll's
    # source_url, because it is the page a reader can actually open.
    def self.article_url(title)
      ARTICLE_BASE + ERB::Util.url_encode(title.to_s.tr(" ", "_"))
    end

    # Pacing and backoff exist to be kind to a live server. The suite never
    # reaches one — WebMock blocks the network outright — so both default to
    # zero under test rather than making every case wait on a wall clock that
    # is not measuring anything. Tests that are *about* pacing pass their own
    # values.
    def initialize(min_interval: nil, backoff_base: nil, sleeper: nil)
      @min_interval = min_interval || (Rails.env.test? ? 0 : MIN_INTERVAL)
      @backoff_base = backoff_base || (Rails.env.test? ? 0 : BACKOFF_BASE)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @last_request_finished_at = nil
    end

    # Returns the page's Parsoid HTML as a UTF-8 string.
    # Raises NotFound (404) or FetchFailed (everything else).
    def page_html(title)
      uri = URI.parse(ENDPOINT + ERB::Util.url_encode(title.to_s))

      (REDIRECT_LIMIT + 1).times do
        response = fetch(uri, title)
        return body_of(response) unless response.is_a?(Net::HTTPRedirection)

        uri = redirect_target(uri, response, title)
      end

      raise FetchFailed, "#{title}: more than #{REDIRECT_LIMIT} redirects"
    end

    private
      def fetch(uri, title)
        attempt = 0

        begin
          attempt += 1
          throttle!
          response = perform(uri)

          case response
          when Net::HTTPSuccess, Net::HTTPRedirection
            response
          when Net::HTTPNotFound
            raise NotFound, "#{title}: 404 from #{uri}"
          when Net::HTTPServerError
            raise FetchFailed, "#{title}: HTTP #{response.code} from #{uri}"
          else
            # 4xx other than 404: retrying will not help.
            raise NotFound, "#{title}: HTTP #{response.code} from #{uri}" if response.is_a?(Net::HTTPClientError)

            raise FetchFailed, "#{title}: HTTP #{response.code} from #{uri}"
          end
        rescue FetchFailed, *RETRIABLE_ERRORS => e
          raise FetchFailed, "#{title}: #{e.class}: #{e.message}" if attempt >= ATTEMPTS

          @sleeper.call(@backoff_base * (2**(attempt - 1)))
          retry
        end
      end

      def perform(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        begin
          http.request(Net::HTTP::Get.new(uri, "User-Agent" => user_agent, "Accept" => "text/html"))
        ensure
          @last_request_finished_at = monotonic_now
          http.finish if http.started?
        end
      end

      def redirect_target(uri, response, title)
        location = response["location"]
        raise FetchFailed, "#{title}: redirect with no Location header" if location.blank?

        target = URI.join(uri, location)
        unless target.host == uri.host && target.scheme == uri.scheme
          raise FetchFailed, "#{title}: refusing off-host redirect to #{target}"
        end

        target
      end

      def body_of(response)
        body = response.body.to_s
        body.dup.force_encoding(Encoding::UTF_8)
      end

      # One request per @min_interval seconds, measured from the end of the
      # previous request so a slow response never earns us extra credit.
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
