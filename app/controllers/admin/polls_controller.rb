module Admin
  # Polls index/show/new/edit/update/destroy. New and edit both funnel
  # through the single-door services: Ingest::RecordPoll for a brand new
  # poll (entry_mode: :manual — the exact door the scraper and CSV import
  # use, just a different entry_mode), Admin::UpdatePoll for an existing one
  # (RecordPoll has no "update" mode — see that class for why editing needs
  # its own digest/collision handling instead of reusing RecordPoll itself).
  class PollsController < BaseController
    before_action :set_poll, only: [ :show, :edit, :update, :destroy ]

    def index
      @polls = Poll.recent_first.includes(:pollster, :race, :poll_results)
      @polls = @polls.where(race_id: params[:race_id]) if params[:race_id].present?
      @polls = @polls.where(pollster_id: params[:pollster_id]) if params[:pollster_id].present?
      @polls = @polls.where(entry_mode: params[:entry_mode]) if params[:entry_mode].present?
      @polls = @polls.for_generic_ballot if ActiveModel::Type::Boolean.new.cast(params[:generic_ballot_only])

      @races = Race.order(:office, :state, :district)
      @pollsters = Pollster.order(:name)
    end

    def show
    end

    def new
      @values = blank_values
    end

    def edit
      @values = values_from(@poll)
    end

    def create
      attrs = poll_attrs
      results = results_from_params
      outcome = Ingest::RecordPoll.call(attrs, results: results, entry_mode: :manual)

      if outcome.created?
        # Cache-consistency rule (Phase 4): admin poll create/edit/destroy
        # must race.touch the associated race; generic-ballot polls (no
        # race) need no touch.
        outcome.poll.race&.touch
        redirect_to admin_poll_path(outcome.poll), notice: "Poll created."
        return
      end

      @values = params[:poll] || blank_values
      if outcome.duplicate?
        @duplicate_of = existing_poll_for(attrs, results)
        flash.now[:alert] = "A matching poll already exists — see below."
      else
        flash.now[:alert] = outcome.message
      end
      render :new, status: :unprocessable_entity
    end

    def update
      attrs = poll_attrs
      results = results_from_params
      outcome = Admin::UpdatePoll.call(@poll, attrs, results: results)

      if outcome.updated?
        redirect_to admin_poll_path(@poll), notice: "Poll updated."
        return
      end

      @values = params[:poll] || blank_values
      if outcome.duplicate?
        @duplicate_of = outcome.existing
        flash.now[:alert] = "Saving these changes would collide with an existing poll — see below."
      else
        flash.now[:alert] = outcome.message
      end
      render :edit, status: :unprocessable_entity
    end

    def destroy
      race = @poll.race
      @poll.destroy
      race&.touch
      redirect_to admin_polls_path, notice: "Poll deleted."
    end

    private
      def set_poll
        @poll = Poll.find(params[:id])
      end

      def poll_attrs
        poll_params = params.fetch(:poll, {})
        {
          pollster_name: poll_params[:pollster_name],
          race_id: poll_params[:race_id].presence,
          field_start: poll_params[:field_start].presence,
          field_end: poll_params[:field_end],
          sample_size: poll_params[:sample_size].presence,
          population: poll_params[:population].presence,
          sponsor: poll_params[:sponsor],
          source_url: poll_params[:source_url],
          raw_payload: { "entered_via" => "admin_form", "entered_at" => Time.current.iso8601 }
        }
      end

      # Four fixed party rows (dem/rep/ind/other — the whole of PollResult's
      # enum), each optional: a blank pct means that party has no result on
      # this poll (most races don't have an independent, generic ballot has
      # no candidates at all). Only non-blank rows become results.
      #
      # pct goes through Admin::PercentValue rather than a bare #to_f: a
      # typo like "N/A" must come out the other end of this method as
      # something Ingest::RecordPoll/Admin::UpdatePoll's own
      # pct.is_a?(Numeric) check rejects, not as #to_f's silent 0.0 — the
      # exact hazard Admin::PollCsvImport already guarded against on the CSV
      # path (see that class), now shared so the two doors can't drift.
      def results_from_params
        rows = params.dig(:poll, :results)
        return [] if rows.blank?

        # ActionController::Parameters doesn't implement the full Enumerable
        # (no #filter_map) — to_unsafe_h is safe here because every value is
        # read one scalar at a time (party/pct/candidate_id) rather than
        # mass-assigned to a model.
        rows.to_unsafe_h.filter_map do |party, row|
          next if row["pct"].blank?

          {
            party: party, pct: Admin::PercentValue.parse(row["pct"]),
            candidate: row["candidate_id"].presence && Candidate.find_by(id: row["candidate_id"])
          }
        end
      end

      # Duplicate detection inside Ingest::RecordPoll doesn't hand back the
      # poll it collided with (its Result#poll is nil for entry_mode:
      # :duplicate — see that class), so the friendly "here's the existing
      # one" link is found the same way RecordPoll found it in the first
      # place: canonicalize the pollster, recompute the exact same digest,
      # look it up. Both calls are the same public pure functions RecordPoll
      # itself uses, not a reimplementation of its dedup rule.
      def existing_poll_for(attrs, results)
        slug = Pollster.canonicalize(attrs[:pollster_name].to_s)
        digest = Poll.compute_digest(
          pollster_slug: slug, race_id: attrs[:race_id],
          field_start: attrs[:field_start], field_end: attrs[:field_end],
          results: results.map { |result| { "party" => result[:party].to_s, "pct" => result[:pct] } }
        )
        Poll.find_by(dedup_digest: digest)
      end

      def blank_values
        { "results" => {} }.with_indifferent_access
      end

      # The shape the form partial reads from either way: a hash-like
      # (indifferent-access) object with pollster_name/race_id/.../results,
      # results being {party => {pct:, candidate_id:}}. On GET it's built
      # from the real poll; on a rejected POST/PATCH it's just the params
      # that were submitted (see #create/#update), so the editor doesn't
      # lose what they typed to a validation error.
      def values_from(poll)
        results = PollResult.parties.keys.index_with { {} }
        poll.poll_results.each do |result|
          results[result.party] = { "pct" => result.pct, "candidate_id" => result.candidate_id }
        end

        {
          "pollster_name" => poll.pollster&.name, "race_id" => poll.race_id, "field_start" => poll.field_start,
          "field_end" => poll.field_end, "sample_size" => poll.sample_size, "population" => poll.population,
          "sponsor" => poll.sponsor, "source_url" => poll.source_url, "results" => results
        }.with_indifferent_access
      end
  end
end
