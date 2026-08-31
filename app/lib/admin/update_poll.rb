module Admin
  # The admin-only counterpart to Ingest::RecordPoll for an EXISTING poll.
  # RecordPoll's contract is create-or-report-duplicate for a brand new row;
  # editing is a different problem — the (possibly changed) pollster/race/
  # dates/results recompute to a new digest, which must be guarded against
  # colliding with a DIFFERENT poll while leaving the row being edited alone
  # (its own current digest is not a collision with itself). Status is
  # :updated, :duplicate or :invalid — the same never-raises contract as
  # RecordPoll. Validation (pollster name, source_url, field_end, at least
  # one well-formed result) is the exact same rules as RecordPoll's, kept as
  # its own copy here rather than a shared extraction — the two doors are
  # independent call sites, each with its own test coverage (test/lib/
  # ingest/record_poll_test.rb, test/lib/admin/update_poll_test.rb), and
  # four blank/format checks are cheaper to duplicate than to indirect.
  class UpdatePoll
    STATUSES = %i[updated duplicate invalid].freeze

    Result = Struct.new(:status, :poll, :message, :existing, keyword_init: true) do
      STATUSES.each { |name| define_method(:"#{name}?") { status == name } }
    end

    def self.call(poll, attrs, results:)
      new(poll, attrs, results: results).call
    end

    def initialize(poll, attrs, results:)
      @poll = poll
      @attrs = attrs.symbolize_keys
      @results = Array(results).map { |result| result.respond_to?(:to_h) ? result.to_h.symbolize_keys : result }
    end

    def call
      problem = validation_problem
      return invalid(problem) if problem

      pollster = find_or_create_pollster
      digest = Poll.compute_digest(
        pollster_slug: pollster.slug, race_id: race_id,
        field_start: @attrs[:field_start], field_end: @attrs[:field_end],
        results: digest_results, salt: @poll.nyt_question_id
      )

      colliding = Poll.where.not(id: @poll.id).find_by(dedup_digest: digest)
      return duplicate(colliding) if colliding

      update!(pollster, digest)
    end

    private
      def update!(pollster, digest)
        old_race_id = @poll.race_id

        Poll.transaction do
          @poll.assign_attributes(
            pollster: pollster,
            race_id: race_id,
            field_start: @attrs[:field_start],
            field_end: @attrs[:field_end],
            sample_size: @attrs[:sample_size],
            population: @attrs[:population].presence || :unknown,
            sponsor: @attrs[:sponsor].presence,
            source_url: @attrs[:source_url],
            dedup_digest: digest
          )
          @poll.poll_results.destroy_all
          @results.each do |result|
            @poll.poll_results.build(party: result[:party], pct: result[:pct], candidate: result[:candidate])
          end
          @poll.save!
        end

        # The cache-consistency rule (Phase 4): a poll edit that moves a poll
        # onto, off of, or between races must leave BOTH the old and new
        # race's updated_at moved, or the public race page's fragment cache
        # can keep showing the poll list as it was before the edit.
        [ old_race_id, race_id ].compact.uniq.each { |id| Race.find(id).touch }

        Result.new(status: :updated, poll: @poll)
      rescue ActiveRecord::RecordNotUnique
        duplicate(Poll.find_by(dedup_digest: digest))
      rescue ActiveRecord::RecordInvalid => e
        invalid(e.record.errors.full_messages.to_sentence)
      end

      def validation_problem
        return "pollster name is required" if @attrs[:pollster_name].blank?
        return "source_url is required" if @attrs[:source_url].blank?
        return "field_end is required" if @attrs[:field_end].blank?
        return "at least one result is required" if @results.empty?

        bad = @results.find { |result| !valid_result?(result) }
        return "result #{bad.inspect} is not a party/pct pair" if bad

        nil
      end

      def valid_result?(result)
        return false unless result.is_a?(Hash)
        return false unless PollResult.parties.key?(result[:party].to_s)

        pct = result[:pct]
        pct.is_a?(Numeric) && pct >= 0 && pct <= 100
      end

      def digest_results
        @results.map { |result| { "party" => result[:party].to_s, "pct" => result[:pct] } }
      end

      def race_id
        @race_id ||= @attrs[:race_id] || @attrs[:race]&.id
      end

      def find_or_create_pollster
        name = @attrs[:pollster_name].to_s.strip
        slug = Pollster.canonicalize(name)
        Pollster.find_by(slug: slug) || Pollster.create!(slug: slug, name: name)
      rescue ActiveRecord::RecordNotUnique
        Pollster.find_by!(slug: slug)
      end

      def duplicate(existing)
        Result.new(status: :duplicate, existing: existing)
      end

      def invalid(message)
        Result.new(status: :invalid, message: message)
      end
  end
end
