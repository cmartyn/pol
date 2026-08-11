module Newsroom
  # After every successful model run — ingest-triggered or the 06:30 cron one —
  # check whether any race has moved far enough since last week to be worth a
  # note. Most runs find nothing and write nothing.
  class MovementNotesJob < ApplicationJob
    queue_as :default

    KIND = :movement_note

    def perform(model_run_id:)
      return unless Newsroom.clear_to_write?(kind: KIND)

      model_run = ModelRun.find_by(id: model_run_id)
      return log("run #{model_run_id} is gone; nothing to compare") unless model_run

      comparison = Movement.call(model_run: model_run)
      return log("no earlier run to compare run #{model_run.id} against") unless comparison
      return log("nothing moved past the threshold in run #{model_run.id}") if comparison.races.empty?

      comparison.races.each { |moved| write(moved, model_run, comparison.previous_run) }
    end

    private
      def write(moved, model_run, previous_run)
        race = moved.race
        reason, detail = Caps.blocking(kind: KIND, race: race)
        if reason
          NewsroomSkip.record!(kind: KIND, race: race, reason: reason, detail: detail)
          return
        end

        Writer.call(
          kind: KIND,
          race: race,
          model_run: model_run,
          payload: Context.movement_note(race: race, model_run: model_run, previous_run: previous_run)
        )
      end

      def log(message)
        Rails.logger.info("Newsroom::MovementNotesJob: #{message}")
        nil
      end
  end
end
