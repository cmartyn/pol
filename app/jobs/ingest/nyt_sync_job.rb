module Ingest
  # The scheduled feed sweep. GoodJob's cron runs this every
  # feed.cadence_hours hours (see config/initializers/good_job.rb).
  class NytSyncJob < ApplicationJob
    queue_as :default

    def perform
      outcomes = Nyt::Sync.new.call
      Rails.logger.info(
        "Ingest::NytSyncJob: #{outcomes.size} files, " \
        "#{outcomes.sum(&:created)} new, #{outcomes.sum(&:duplicate)} duplicate, " \
        "#{outcomes.count { |outcome| outcome.status == :failed }} failed"
      )
      outcomes
    end
  end
end
