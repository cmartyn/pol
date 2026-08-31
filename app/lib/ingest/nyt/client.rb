require "net/http"

module Ingest
  module Nyt
    # Fetches one of the NYT poll CSVs. Same manners as WikipediaClient —
    # descriptive User-Agent with a contact address, hard timeouts, a few
    # retries with backoff — minus the request pacing: there are two files a
    # sync, not sixty-nine pages.
    #
    # Sends If-Modified-Since from the caller's last change and returns
    # :not_modified on a 304, so a quiet feed costs neither side the body.
    class Client
      Error = Class.new(StandardError)
      FetchFailed = Class.new(Error)

      BASE = "https://www.nytimes.com/newsgraphics/polls/".freeze
      SOURCES = %w[senate.csv house.csv].freeze

      OPEN_TIMEOUT = 15
      READ_TIMEOUT = 30
      ATTEMPTS = 3
      BACKOFF_BASE = 0.5

      RETRIABLE_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
        Errno::EHOSTUNREACH, EOFError, SocketError
      ].freeze

      def self.url_for(source)
        BASE + source
      end

      def initialize(backoff_base: nil, sleeper: nil)
        @backoff_base = backoff_base || (Rails.env.test? ? 0 : BACKOFF_BASE)
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      # The CSV body as a UTF-8 string, or :not_modified. Candidate names
      # carry accents, so the bytes are forced to UTF-8 and scrubbed rather
      # than left to default to US-ASCII and raise mid-parse.
      def fetch(source, since: nil)
        raise ArgumentError, "unknown source #{source.inspect}" unless SOURCES.include?(source)

        response = with_retries(source) { get(URI(self.class.url_for(source)), since: since) }
        return :not_modified if response.is_a?(Net::HTTPNotModified)

        unless response.is_a?(Net::HTTPOK)
          raise FetchFailed, "#{source}: HTTP #{response.code}"
        end

        body = response.body.to_s.dup.force_encoding(Encoding::UTF_8)
        body.valid_encoding? ? body : body.scrub
      end

      private
        def get(uri, since:)
          headers = { "User-Agent" => user_agent, "Accept" => "text/csv" }
          headers["If-Modified-Since"] = since.httpdate if since

          Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
            http.request(Net::HTTP::Get.new(uri, headers))
          end
        end

        def with_retries(source)
          attempts = 0
          begin
            attempts += 1
            yield
          rescue *RETRIABLE_ERRORS => error
            raise FetchFailed, "#{source}: #{error.class}: #{error.message}" if attempts >= ATTEMPTS

            @sleeper.call(@backoff_base * (2**(attempts - 1)))
            retry
          end
        end

        def user_agent
          "pol/0.1 (2026 midterms forecast site; contact: #{Pol::Params.fetch!(:scrape, :user_agent_contact)})"
        end
    end
  end
end
