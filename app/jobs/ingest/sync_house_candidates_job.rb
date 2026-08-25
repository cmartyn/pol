module Ingest
  # The daily sync that keeps each House race's candidate list in step with
  # its Wikipedia page. Ingest::ScrapeAllJob's 2-hourly sweep only reads the
  # states with district polling (Sources::DISTRICT_POLL_STATES); a
  # district's nominee can settle in a state nobody is polling yet, so this
  # covers every state that holds a House race in the cycle instead.
  class SyncHouseCandidatesJob < ApplicationJob
    queue_as :default

    Outcome = Struct.new(:source, :status, :fetched, :synced, :skipped, :error, keyword_init: true)

    def perform
      client = WikipediaClient.new
      outcomes = states.map { |state, races| sync_state(state, races, client) }

      Rails.logger.info(
        "Ingest::SyncHouseCandidatesJob: #{outcomes.size} state(s), " \
        "#{outcomes.sum(&:synced)} district(s) synced, " \
        "#{outcomes.count { |outcome| outcome.status == :failed }} failed"
      )
      outcomes
    end

    private
      # Every state with a House race, not Sources.district_states' capped
      # list — that cap exists because the 2-hourly poll sweep cannot afford
      # fifty fetches every two hours, and this job runs once a day.
      def states
        Race.house.where(cycle: Sources.cycle).includes(:candidates).group_by(&:state).sort
      end

      def sync_state(state, races, client)
        title = Sources.district_title(state, single_district: races.one?)
        started_at = Time.current
        tally = { fetched: 0, synced: 0, skipped: 0, warnings: [] }
        status = :succeeded
        error = nil

        begin
          sync_page(title, races, client, tally)
          status, error = outcome_of(tally)
        rescue WikipediaClient::NotFound => e
          status = :partial
          error = "page not available: #{e.message}"
          Rails.logger.warn("Ingest::SyncHouseCandidatesJob #{title}: #{error}")
        rescue StandardError => e
          status = :failed
          error = "#{e.class}: #{e.message}"
          Rails.logger.error("Ingest::SyncHouseCandidatesJob #{title}: #{error}")
        end

        record(title, status, tally, error, started_at)
      end

      def outcome_of(tally)
        return [ :succeeded, nil ] if tally[:skipped].zero?

        [ :partial, "#{tally[:skipped]} district(s) skipped: no matching race" ]
      end

      def sync_page(title, races, client, tally)
        parser = HouseCandidatesParser.new(html: client.page_html(title), page_url: WikipediaClient.article_url(title))
        districts = parser.call
        tally[:fetched] = districts.size

        by_district = races.index_by(&:district)

        # A district absent from the parser's output — its primary has not
        # happened, or the box could not be read — is left completely alone:
        # no prune, no delete. A page restructure or parse gap must never
        # mass-delete seeded candidates.
        districts.each do |number, entries|
          race = by_district[number]
          # Mirrors Ingest::Scraper's "no race for district" guard: counted
          # and left alone rather than guessed at.
          if race.nil?
            tally[:skipped] += 1
            Rails.logger.warn("Ingest::SyncHouseCandidatesJob #{title}: no race for district #{number}")
            next
          end

          sync_race(race, entries, tally)
        end

        parser.warnings.each { |warning| Rails.logger.warn("Ingest::SyncHouseCandidatesJob #{title}: #{warning}") }
      end

      # The infobox carries no caucus fact — Ingest::HouseCandidatesParser's
      # entries never include the key — so forwarding an entry as-is would
      # null out whatever an admin set by hand for an Alaska-style
      # independent. Carrying each candidate's current value forward is what
      # makes a daily re-sync safe.
      def sync_race(race, entries, tally)
        current = race.candidates.index_by(&:name)
        entries = entries.map { |entry| entry.merge("caucus_with" => current[entry.fetch("name")]&.caucus_with) }

        # The infobox names only the leading candidates per party, not the
        # whole ballot (see HouseCandidatesParser's own header comment), so a
        # full prune would delete a hand-added minor candidate the page never
        # mentions. :listed_parties prunes only the parties these entries
        # cover, which still lets a replaced same-party nominee be removed.
        CandidateSync.apply(race, entries, warnings: tally[:warnings], prune: :listed_parties)
        tally[:synced] += 1
      end

      def record(title, status, tally, error, started_at)
        tally[:warnings].each { |warning| Rails.logger.warn("Ingest::SyncHouseCandidatesJob #{title}: #{warning}") }

        # duplicate_count and refused_count/refusal_reasons are left at their
        # defaults: that vocabulary is Ingest::PollTableParser's (an
        # already-known poll; a table declined on purpose), and neither
        # concept exists on this side of the sweep.
        ScrapeRun.create!(
          source: title,
          status: status,
          fetched_count: tally[:fetched],
          new_count: tally[:synced],
          error_message: error,
          started_at: started_at,
          finished_at: Time.current
        )

        Outcome.new(source: title, status: status, fetched: tally[:fetched], synced: tally[:synced],
                    skipped: tally[:skipped], error: error)
      end
  end
end
