module Ingest
  # Sweeps every poll source once: each Senate race's Wikipedia page, the
  # generic congressional ballot, then each state House page that carries
  # district polling. One ScrapeRun row per source, and a single source never
  # takes the sweep down — its failure is recorded and the sweep moves on.
  class Scraper
    # poll_ids are the polls this source actually created, which is what the
    # newsroom reacts to downstream; `created` stays as the count the sweep
    # report and the ScrapeRun row are written from. `refusals` maps a
    # PollTableParser refusal reason to how many tables it fired on.
    Outcome = Struct.new(
      :source, :status, :fetched, :created, :duplicate, :skipped, :invalid, :refused, :refusals,
      :error, :poll_ids,
      keyword_init: true
    )

    # `write` — whether parsed polls are recorded at all. Since the NYT feed
    # became the corpus, the sweep's production job is canary duty: parse
    # every page, account for every table in scrape_runs so layout rot still
    # alarms, write nothing. scrape.write_enabled arms it back into a real
    # fallback with one params flip (see docs/DEPLOY.md).
    def initialize(client: WikipediaClient.new, logger: Rails.logger,
                   write: Pol::Params.fetch!(:scrape, :write_enabled))
      @client = client
      @logger = logger
      @write = write
    end

    # => [Outcome, ...], one per source, in the order they were scraped.
    def call
      outcomes = senate_races.map { |race| scrape(Sources.senate_title(race), race: race) }
      outcomes << scrape(Sources.generic_ballot_title, race: nil)
      outcomes.concat(district_outcomes)

      created_poll_ids = outcomes.flat_map(&:poll_ids)
      Ingest.after_new_polls!(created_poll_ids) if created_poll_ids.any?

      outcomes
    end

    private
      def senate_races
        Race.senate.where(cycle: Sources.cycle).order(:slug).includes(:candidates)
      end

      # A state's House page is one source covering many races, so the district
      # each row belongs to has to be resolved before a poll can be written.
      def district_outcomes
        kept, dropped = Sources.district_states
        if dropped.any?
          @logger.warn("Ingest::Scraper: scrape.max_district_sources capped the sweep; " \
                       "skipped #{dropped.size} state page(s): #{dropped.join(', ')}")
        end

        by_state = Race.house.where(cycle: Sources.cycle, state: kept).includes(:candidates).group_by(&:state)

        kept.filter_map do |state|
          races = by_state[state]
          next if races.blank?

          scrape(Sources.district_title(state, single_district: races.one?), races: races)
        end
      end

      def scrape(title, race: nil, races: nil)
        started_at = Time.current
        tally = { fetched: 0, created: 0, duplicate: 0, skipped: 0, invalid: 0,
                  refused: 0, refusals: {}, poll_ids: [] }
        status = :succeeded
        error = nil

        begin
          races ? ingest_districts(title, races, tally) : ingest(title, race, tally)
          status, error = outcome_of(tally)
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

      # Everything a completed parse can say about itself, in one place. Which
      # refusals make a source `partial` rather than clean is ScrapeRun's
      # policy (see its constants); this reads it rather than restating it.
      def outcome_of(tally)
        problems = []
        problems << "#{tally[:skipped]} row(s) skipped" if tally[:skipped].positive?
        problems << "#{tally[:invalid]} rejected" if tally[:invalid].positive?

        unreadable = tally[:refusals].slice(*ScrapeRun::UNREADABLE_REASONS)
        declined = tally[:refusals].except(ScrapeRun::EMPTY_PAGE_REASON)

        if unreadable.any?
          problems << "#{unreadable.values.sum} table(s) not recognised (#{reason_list(unreadable)})"
        elsif tally[:refused].positive? && tally[:fetched].zero?
          problems << "no polls read; refused #{reason_list(declined)}"
        end

        return [ :succeeded, nil ] if problems.empty?

        [ :partial, problems.join(", ") ]
      end

      def reason_list(refusals)
        refusals.sort.map { |reason, count| "#{reason} ×#{count}" }.join(", ")
      end

      def ingest(title, race, tally)
        result = PollTableParser.new(
          html: @client.page_html(title),
          page_url: WikipediaClient.article_url(title),
          candidates: race ? race.candidates.to_a : []
        ).call

        absorb(result, tally)
        result.rows.each { |row| record_poll(title, row, race, tally) }
      end

      def ingest_districts(title, races, tally)
        by_district = races.index_by(&:district)

        result = PollTableParser.new(
          html: @client.page_html(title),
          page_url: WikipediaClient.article_url(title),
          scope: :district,
          district_candidates: races.to_h { |race| [ race.district, race.candidates.to_a ] },
          # A state with one at-large district has no "District N" heading to
          # read, because there is only the one district to mean.
          default_district: (races.sole.district if races.one?)
        ).call

        absorb(result, tally)

        result.rows.each do |row|
          race = by_district[row.district]
          # The district was named on the page but we hold no race for it.
          # Counted and left alone: guessing which race a poll belongs to is
          # the one thing worse than not having the poll.
          if race.nil?
            tally[:skipped] += 1
            @logger.warn("Ingest::Scraper #{title}: no race for district #{row.district.inspect}")
            next
          end

          record_poll(title, row, race, tally)
        end
      end

      # Reason keys become strings here and stay strings: that is the shape
      # they are stored in, so nothing downstream has to remember which side of
      # the database it is on.
      def absorb(result, tally)
        tally[:fetched] = result.fetched
        tally[:skipped] = result.skipped
        tally[:refused] = result.refused
        tally[:refusals] = result.refusals.transform_keys(&:to_s)
      end

      def record_poll(title, row, race, tally)
        return dry_record(row, race, tally) unless @write

        outcome = RecordPoll.call(attributes_for(row, race), results: results_for(row), entry_mode: :scraped)
        tally[outcome.status == :created ? :created : outcome.status] += 1
        tally[:poll_ids] << outcome.poll.id if outcome.created?
        @logger.warn("Ingest::Scraper #{title}: rejected row — #{outcome.message}") if outcome.invalid?
      end

      # The canary's accounting: what a live sweep would have done, with no
      # poll row written and no pollster created. `created` counts the
      # would-creates — the number an operator reads as "the fallback still
      # sees polls the corpus would have gained" — and poll_ids stays empty,
      # so no forecast run is ever queued from a dry sweep.
      def dry_record(row, race, tally)
        attrs = attributes_for(row, race)
        pollster = Pollster.find_by(slug: Pollster.canonicalize(attrs[:pollster_name].to_s))
        digest = pollster && Poll.compute_digest(
          pollster_slug: pollster.slug, race_id: race&.id,
          field_start: attrs[:field_start], field_end: attrs[:field_end],
          results: results_for(row).map { |result| { "party" => result[:party].to_s, "pct" => result[:pct] } }
        )

        tally[digest && Poll.exists?(dedup_digest: digest) ? :duplicate : :created] += 1
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
          raw_payload: row.raw_payload,
          matchup_key: row.matchup_key
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
          refused_count: tally[:refused],
          refusal_reasons: tally[:refusals],
          error_message: error,
          started_at: started_at,
          finished_at: Time.current
        )

        Outcome.new(
          source: title, status: status, fetched: tally[:fetched], created: tally[:created],
          duplicate: tally[:duplicate], skipped: tally[:skipped], invalid: tally[:invalid],
          refused: tally[:refused], refusals: tally[:refusals], error: error,
          poll_ids: tally[:poll_ids]
        )
      end
  end
end
