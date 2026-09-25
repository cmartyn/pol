module Newsroom
  # After every successful model run — ingest-triggered or the 06:30 cron one —
  # check whether any race has moved far enough since last week, or since the
  # newsroom last wrote about it, to be worth a note. Most runs find nothing
  # and write nothing.
  class MovementNotesJob < ApplicationJob
    queue_as :default

    KIND = :movement_note

    def perform(model_run_id:)
      model_run = ModelRun.find_by(id: model_run_id)
      return log("run #{model_run_id} is gone; nothing to compare") unless model_run

      comparison = Movement.call(model_run: model_run)
      return log("no earlier run to compare run #{model_run.id} against") unless comparison
      return log("nothing moved past the threshold in run #{model_run.id}") if comparison.races.empty?

      comparison.races.each { |moved| write(moved, model_run) }
    end

    private
      # Most runs find nothing moved and reach none of this. The kill switch is
      # checked here, once per race that actually cleared the threshold, so a
      # quiet week under a disabled newsroom writes no skip rows at all.
      # The note is measured, and written, from the race's own baseline run —
      # last week's, or the last note's (Newsroom::Movement) — not from the
      # comparison run shared across the board.
      def write(moved, model_run)
        race = moved.race
        return unless Newsroom.clear_to_write?(kind: KIND, race: race)

        reason, detail = Caps.blocking(kind: KIND, race: race)
        if reason
          record_hold(race, reason, detail)
          return
        end

        Writer.call(
          kind: KIND,
          race: race,
          model_run: model_run,
          payload: Context.movement_note(race: race, model_run: model_run, previous_run: moved.baseline_run)
        )
      end

      # A cap or a cooldown holds a race for hours or days, and this job runs
      # after every model run, so recording each re-detection wrote the same
      # hold over and over: by 2026-09-25 these were 2,273 of the skip log's
      # 2,389 rows, one race 42 times in 56 hours, and the dashboard's "cap
      # reached today" was counting runs rather than races held. One row per
      # race and reason per Eastern day — Caps.day_range, the same day the
      # dashboard counts — says what all of those said. The repeats still go
      # to the log, so none of them is silent.
      def record_hold(race, reason, detail)
        if NewsroomSkip.where(kind: KIND, race: race, reason: reason, created_at: Caps.day_range).exists?
          return log("#{race.slug} is still held (#{reason}); today's skip log already has it")
        end

        NewsroomSkip.record!(kind: KIND, race: race, reason: reason, detail: detail)
      end

      def log(message)
        Rails.logger.info("Newsroom::MovementNotesJob: #{message}")
        nil
      end
  end
end
