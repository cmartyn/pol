module Ingest
  module Nyt
    # Repair existing questions from their saved source rows. A normal sync
    # skips known question IDs, so fixing Mapper alone cannot repair them.
    # Poll IDs and timestamps survive; this never queues a forecast or news.
    class Reprocess
      def initialize(scope: Poll.nyt)
        @scope = scope
      end

      def call(apply: false)
        report = { checked: 0, changed: 0, result_counts_changed: 0, changes: [] }
        mapper = Mapper.new(source: "stored-questions")
        Poll.transaction do
          @scope.order(:id).lock(apply).includes(:poll_results, :pollster).each do |poll|
            rows = poll.raw_payload&.dig("nyt", "rows")
            raise "Missing source rows for poll #{poll.id}" if rows.blank?

            outcome = mapper.map(CsvParser::Question.new(question_id: poll.nyt_question_id, rows: rows))
            raise "Cannot remap poll #{poll.id}: #{outcome.reason || outcome.status}" unless outcome.mapped?
            raise "Race changed for poll #{poll.id}" unless outcome.attrs[:race]&.id == poll.race_id

            report[:checked] += 1
            results = outcome.results.map do |result|
              result.except(:candidate).merge(candidate_id: result[:candidate]&.id).stringify_keys
            end
            old_results = poll.poll_results.map { |result| result.attributes.slice(*results.first.keys) }
            payload = poll.raw_payload.merge(outcome.attrs[:raw_payload]).merge(
              "nyt" => poll.raw_payload.fetch("nyt").merge(outcome.attrs[:raw_payload].fetch("nyt")).merge("rows" => rows))
            next if canonical(old_results) == canonical(results) && poll.matchup_key == outcome.attrs[:matchup_key] && poll.raw_payload == payload

            report[:changed] += 1
            report[:result_counts_changed] += 1 if old_results.size != results.size
            report[:changes] << { id: poll.id, race_id: poll.race_id,
                                  old_matchup: poll.matchup_key, new_matchup: outcome.attrs[:matchup_key],
                                  old_results: old_results, new_results: results }
            next unless apply

            digest = Poll.compute_digest(pollster_slug: poll.pollster.slug, race_id: poll.race_id,
              field_start: poll.field_start, field_end: poll.field_end, results: results, salt: poll.nyt_question_id)
            poll.poll_results.destroy_all
            results.each { |result| poll.poll_results.create!(result) }
            poll.update!(matchup_key: outcome.attrs[:matchup_key], raw_payload: payload, dedup_digest: digest)
          end
        end
        report
      end

      private
        def canonical(results)
          results.map { |result| result.sort.to_h.to_json }.sort
        end
    end
  end
end
