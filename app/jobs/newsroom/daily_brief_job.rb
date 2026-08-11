module Newsroom
  # The 07:00 America/New_York national brief (and `bin/rails pol:brief`, which
  # is the same code path by hand). The 06:30 cron model run goes first, so the
  # brief is always written from that morning's numbers.
  class DailyBriefJob < ApplicationJob
    queue_as :default

    KIND = :daily_brief

    def perform
      model_run = ModelRun.succeeded.latest.first
      unless model_run
        return log("no succeeded model run yet; there is no board to describe")
      end

      # Only once there is a board to describe: a brief that was never going to
      # be written is not a brief the newsroom decided against.
      return unless Newsroom.clear_to_write?(kind: KIND)

      reason, detail = Caps.blocking(kind: KIND)
      if reason
        return NewsroomSkip.record!(kind: KIND, reason: reason, detail: detail)
      end

      Writer.call(kind: KIND, model_run: model_run, payload: Context.daily_brief(model_run: model_run))
    end

    private
      def log(message)
        Rails.logger.info("Newsroom::DailyBriefJob: #{message}")
        nil
      end
  end
end
