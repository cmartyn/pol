module Newsroom
  # One reaction per race that received polls in the sweep that triggered this
  # run. Enqueued by Forecast::RunJob once the run those polls caused has
  # actually succeeded, so the piece can quote a forecast that already includes
  # them (Newsroom.after_model_run!).
  class PollReactionsJob < ApplicationJob
    queue_as :default

    KIND = :poll_reaction

    def perform(model_run_id:, poll_ids: [])
      model_run = ModelRun.find_by(id: model_run_id)
      return log("run #{model_run_id} is gone; nothing to react to") unless model_run

      by_race = polls_by_race(poll_ids)
      return log("no race-level polls in this sweep; nothing to react to") if by_race.empty?

      by_race.each { |race, polls| write(race, polls, model_run) }
    end

    private
      # Generic-ballot polls have no race and get no reaction: they move the
      # national environment, which is the daily brief's subject, not a race's.
      def polls_by_race(poll_ids)
        Poll.where(id: Array(poll_ids))
            .where.not(race_id: nil)
            .includes(:race, :pollster, poll_results: :candidate)
            .group_by(&:race)
      end

      # The kill switch and the API-key check live here, per race, rather than
      # at the top of the job: this is the point where a piece would actually
      # have been written, and it is the only point at which a skip row is
      # worth writing.
      def write(race, polls, model_run)
        return unless Newsroom.clear_to_write?(kind: KIND, race: race)

        poll_ids = polls.map(&:id)
        reason, detail = Caps.blocking(kind: KIND, race: race, poll_ids: poll_ids)
        if reason
          NewsroomSkip.record!(kind: KIND, race: race, reason: reason, detail: detail)
          return
        end

        Writer.call(
          kind: KIND,
          race: race,
          model_run: model_run,
          payload: Context.poll_reaction(race: race, polls: polls, model_run: model_run)
        )
      end

      def log(message)
        Rails.logger.info("Newsroom::PollReactionsJob: #{message}")
        nil
      end
  end
end
