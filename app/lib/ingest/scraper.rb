module Ingest
  # Sweeps every poll source once: each Senate race's Wikipedia page, then the
  # generic congressional ballot. One ScrapeRun row per source, and a single
  # source never takes the sweep down — its failure is recorded and the sweep
  # moves on.
  class Scraper
    # poll_ids are the polls this source actually created, which is what the
    # newsroom reacts to downstream; `created` stays as the count the sweep
    # report and the ScrapeRun row are written from.
    Outcome = Struct.new(
      :source, :status, :fetched, :created, :duplicate, :skipped, :invalid, :error, :poll_ids,
      keyword_init: true
    )

    def initialize(client: WikipediaClient.new, logger: Rails.logger)
      @client = client
      @logger = logger
    end

    # => [Outcome, ...], one per source, in the order they were scraped.
    def call
      outcomes = senate_races.map { |race| scrape(Sources.senate_title(race), race: race) }
      outcomes << scrape(Sources.generic_ballot_title, race: nil)

      created_poll_ids = outcomes.flat_map(&:poll_ids)
      Ingest.after_new_polls!(created_poll_ids) if created_poll_ids.any?

      outcomes
    end

    private
      def senate_races
        Race.senate.where(cycle: Sources.cycle).order(:slug).includes(:candidates)
      end

      def scrape(title, race:)
        started_at = Time.current
        tally = { fetched: 0, created: 0, duplicate: 0, skipped: 0, invalid: 0, poll_ids: [] }
        status = :succeeded
        error = nil

        begin
          ingest(title, race, tally)
          if tally[:skipped].positive? || tally[:invalid].positive?
            status = :partial
            error = "#{tally[:skipped]} row(s) skipped, #{tally[:invalid]} rejected"
          end
        rescue WikipediaClient::NotFound => e
          status = :partial
          error = "page not available: #{e.message}"
          @logger.warn("Ingest::Scraper #{title}: #{error}")
        rescue StandardError => e
          status = :failed
          error = "#{e.class}: #{e.message}"
          @logger.error("Ingest::Scraper #{title}: #{error}")
        end

        record(title, status, tally, error, started_at)
      end

      def ingest(title, race, tally)
        result = PollTableParser.new(
          html: @client.page_html(title),
          page_url: WikipediaClient.article_url(title),
          candidates: race ? race.candidates.to_a : []
        ).call

        tally[:fetched] = result.fetched
        tally[:skipped] = result.skipped

        result.rows.each do |row|
          outcome = RecordPoll.call(attributes_for(row, race), results: results_for(row), entry_mode: :scraped)
          tally[outcome.status == :created ? :created : outcome.status] += 1
          tally[:poll_ids] << outcome.poll.id if outcome.created?
          @logger.warn("Ingest::Scraper #{title}: rejected row — #{outcome.message}") if outcome.invalid?
        end
      end

      def attributes_for(row, race)
        {
          pollster_name: row.pollster,
          race: race,
          sponsor: row.sponsor,
          field_start: row.field_start,
          field_end: row.field_end,
          sample_size: row.sample_size,
          population: row.population,
          source_url: row.source_url,
          raw_payload: row.raw_payload
        }
      end

      def results_for(row)
        row.results.map { |entry| { party: entry.party, pct: entry.pct, candidate: entry.candidate } }
      end

      def record(title, status, tally, error, started_at)
        ScrapeRun.create!(
          source: title,
          status: status,
          fetched_count: tally[:fetched],
          new_count: tally[:created],
          duplicate_count: tally[:duplicate],
          error_message: error,
          started_at: started_at,
          finished_at: Time.current
        )

        Outcome.new(
          source: title, status: status, fetched: tally[:fetched], created: tally[:created],
          duplicate: tally[:duplicate], skipped: tally[:skipped], invalid: tally[:invalid], error: error,
          poll_ids: tally[:poll_ids]
        )
      end
  end
end
