module Ingest
  # The single door every poll comes through, whatever its entry mode: the
  # Wikipedia scraper today, Phase 6's manual entry form and CSV import later.
  #
  #   Ingest::RecordPoll.call(
  #     { pollster_name: "Beacon Polling", race: race, field_start: ...,
  #       field_end: ..., sample_size: 600, population: :lv,
  #       source_url: "https://...", raw_payload: { ... } },
  #     results: [ { party: :dem, pct: 47.5 }, { party: :rep, pct: 44.0 } ]
  #   )
  #   # => #<Result status=:created poll=#<Poll id: 1>>
  #
  # Canonicalises the pollster, computes the dedup digest, applies the dedup
  # contract, and writes the poll and its results in one transaction. Status is
  # :created, :duplicate or :invalid — it never raises for bad input.
  class RecordPoll
    STATUSES = %i[created duplicate invalid].freeze

    Result = Struct.new(:status, :poll, :message, keyword_init: true) do
      STATUSES.each { |name| define_method(:"#{name}?") { status == name } }
    end

    def self.call(attrs, results:, entry_mode: :scraped)
      new(attrs, results: results, entry_mode: entry_mode).call
    end

    def initialize(attrs, results:, entry_mode: :scraped)
      @attrs = attrs.symbolize_keys
      @results = Array(results).map { |result| result.respond_to?(:to_h) ? result.to_h.symbolize_keys : result }
      @entry_mode = entry_mode
    end

    def call
      problem = validation_problem
      return invalid(problem) if problem

      pollster = find_or_create_pollster
      digest = Poll.compute_digest(
        pollster_slug: pollster.slug, race_id: race_id,
        field_start: @attrs[:field_start], field_end: @attrs[:field_end],
        results: digest_results, salt: @attrs[:digest_salt]
      )

      # Belt: the read that lets us report a duplicate without provoking an
      # error. Braces: the DB unique index, rescued below, is what actually
      # guarantees it.
      return duplicate if Poll.exists?(dedup_digest: digest)

      create(pollster, digest)
    end

    private
      def create(pollster, digest)
        poll = nil

        Poll.transaction do
          poll = Poll.new(
            pollster: pollster,
            race_id: race_id,
            field_start: @attrs[:field_start],
            field_end: @attrs[:field_end],
            sample_size: @attrs[:sample_size],
            population: @attrs[:population].presence || :unknown,
            sponsor: @attrs[:sponsor].presence,
            source_url: @attrs[:source_url],
            raw_payload: @attrs[:raw_payload],
            matchup_key: @attrs[:matchup_key],
            partisan: @attrs[:partisan].presence || :none,
            methodology: @attrs[:methodology].presence,
            nyt_poll_id: @attrs[:nyt_poll_id].presence,
            nyt_question_id: @attrs[:nyt_question_id].presence,
            entry_mode: @entry_mode,
            dedup_digest: digest
          )

          @results.each do |result|
            poll.poll_results.build(party: result[:party], pct: result[:pct], candidate: result[:candidate])
          end

          poll.save!
        end

        Result.new(status: :created, poll: poll)
      rescue ActiveRecord::RecordNotUnique
        # Another worker inserted the same digest between our check and this
        # write. Nothing is half-written: the transaction rolled back.
        duplicate
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

      # The NYT feed carries a stable pollster id; when one is present it is
      # the identity, and the slug is only how a brand-new pollster gets
      # named. Looked up by id first so a renamed pollster ("Siena College"
      # becoming "Siena University") updates in place rather than splitting
      # into two houses — the split is what slug-only lookup cannot prevent.
      def find_or_create_pollster
        name = @attrs[:pollster_name].to_s.strip
        slug = Pollster.canonicalize(name)
        nyt_id = @attrs[:nyt_pollster_id].presence

        if nyt_id && (existing = Pollster.find_by(nyt_pollster_id: nyt_id))
          return existing
        end

        pollster = Pollster.find_by(slug: slug) || Pollster.create!(slug: slug, name: name)
        pollster.update!(nyt_pollster_id: nyt_id) if nyt_id && pollster.nyt_pollster_id.nil?
        pollster
      rescue ActiveRecord::RecordNotUnique
        Pollster.find_by!(slug: slug)
      end

      def duplicate
        Result.new(status: :duplicate)
      end

      def invalid(message)
        Result.new(status: :invalid, message: message)
      end
  end
end
