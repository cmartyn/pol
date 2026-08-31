require "digest"

module Ingest
  module Nyt
    # The NYT feed sweep: fetch both CSVs, snapshot what changed, map every
    # in-scope question through the single RecordPoll door, and account for
    # the whole pass in scrape_runs — one row per file, same table and same
    # alarm semantics as the Wikipedia sweep it replaced. In particular,
    # refused questions do NOT count as fetched, so a sweep that refused
    # everything reads fetched 0 and ScrapeRun#dark? can fire — that alarm
    # is the migration's defense against the feed changing vocabulary under
    # us.
    #
    # Failure isolation matches the scraper: any error in one file is a
    # failed run for that file and an untouched pass for the other. New polls
    # from either file queue one forecast run at the end.
    class Sync
      Outcome = Struct.new(:source, :status, :fetched, :created, :duplicate,
                           :skipped, :refused, :refusals, :created_ids, :error,
                           keyword_init: true)

      def initialize(client: Client.new)
        @client = client
      end

      def call
        outcomes = Client::SOURCES.map { |source| sync_source(source) }

        Ingest.after_new_polls!(outcomes.flat_map(&:created_ids))
        outcomes
      end

      private
        def sync_source(source)
          started_at = Time.current
          run_source = "nyt:#{source}"

          body = @client.fetch(source, since: FeedSnapshot.latest_meta_for(run_source)&.fetched_at)
          counts = ingest_changed(source, run_source, body)

          status, message = staleness(run_source, counts)
          record_run(run_source, status, counts, message, started_at)
        rescue StandardError => error
          record_run(run_source, :failed, empty_counts, "#{error.class}: #{error.message}", started_at)
        end

        # Parse and map only when the content actually changed — the files
        # hold the whole cycle and gain a handful of polls a day, so most
        # sweeps end here. The snapshot is recorded only AFTER a clean parse
        # and ingest: snapshotting first would arm the next sweep's
        # If-Modified-Since against a body we never read, and one truncated
        # download could then suppress that content version forever behind
        # 304s.
        def ingest_changed(source, run_source, body)
          return empty_counts if body == :not_modified

          last = FeedSnapshot.latest_meta_for(run_source)
          return empty_counts if last && last.digest == Digest::SHA256.hexdigest(body)

          counts = ingest(source, CsvParser.new.parse(body))
          FeedSnapshot.record!(source: run_source, body: body)
          FeedSnapshot.prune!(run_source)
          counts
        end

        def ingest(source, questions)
          mapper = Mapper.new(source: source)
          known = Poll.where(nyt_question_id: questions.map(&:question_id))
                      .pluck(:nyt_question_id).to_set
          counts = empty_counts

          questions.each do |question|
            # A question already ingested needs no re-mapping — its id is on
            # the row. This is an optimization in front of RecordPoll's own
            # dedup (the digest check and the nyt_question_id unique index),
            # not the guarantee itself.
            if known.include?(question.question_id)
              counts[:fetched] += 1
              counts[:duplicate] += 1
              next
            end

            outcome = mapper.map(question)
            if outcome.skipped?
              counts[:skipped] += 1
            elsif outcome.refused?
              refuse(counts, outcome.reason)
            else
              counts[:fetched] += 1
              record(counts, outcome)
            end
          end

          counts
        end

        def record(counts, outcome)
          result = RecordPoll.call(outcome.attrs, results: outcome.results, entry_mode: :nyt)

          if result.created?
            counts[:created] += 1
            counts[:created_ids] << result.poll.id
          elsif result.duplicate?
            counts[:duplicate] += 1
          else
            # RecordPoll never raises for bad input; an invalid here means
            # the mapper let something malformed through, which is worth a
            # counted reason rather than a silent drop.
            refuse(counts, "record_invalid")
            Rails.logger.warn("Ingest::Nyt::Sync: invalid poll refused: #{result.message}")
          end
        end

        def refuse(counts, reason)
          counts[:refused] += 1
          counts[:refusals][reason] = counts[:refusals].fetch(reason, 0) + 1
        end

        # A feed that fetches cleanly but never changes is indistinguishable
        # from a feed the Times stopped updating — and that silence is the
        # one failure mode this migration must not inherit from Wikipedia.
        # No snapshot at all is fine (first run); an old one is the alarm.
        def staleness(run_source, counts)
          return [ :succeeded, nil ] if counts[:created].positive?

          latest = FeedSnapshot.latest_meta_for(run_source)
          return [ :succeeded, nil ] if latest.nil?

          age_days = (Time.current - latest.fetched_at) / 1.day
          limit = Pol::Params.fetch!(:feed, :staleness_alarm_days)
          return [ :succeeded, nil ] if age_days < limit

          [ :partial, "feed content unchanged for #{age_days.floor} days" ]
        end

        def record_run(run_source, status, counts, message, started_at)
          run = ScrapeRun.create!(
            source: run_source,
            status: status,
            fetched_count: counts[:fetched],
            new_count: counts[:created],
            duplicate_count: counts[:duplicate],
            refused_count: counts[:refused],
            refusal_reasons: counts[:refusals],
            error_message: message,
            started_at: started_at,
            finished_at: Time.current
          )

          Outcome.new(source: run.source, status: run.status.to_sym,
                      fetched: counts[:fetched], created: counts[:created],
                      duplicate: counts[:duplicate], skipped: counts[:skipped],
                      refused: counts[:refused], refusals: counts[:refusals],
                      created_ids: counts[:created_ids], error: message)
        end

        def empty_counts
          { fetched: 0, created: 0, duplicate: 0, skipped: 0, refused: 0, refusals: {}, created_ids: [] }
        end
    end
  end
end
