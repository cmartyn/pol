module Ingest
  # The scheduled sweep. GoodJob's cron runs this every
  # scrape.cadence_hours hours (see config/initializers/good_job.rb).
  class ScrapeAllJob < ApplicationJob
    queue_as :default

    def perform
      outcomes = Scraper.new.call
      Rails.logger.info(
        "Ingest::ScrapeAllJob: #{outcomes.size} sources, " \
        "#{outcomes.sum(&:created)} new, #{outcomes.sum(&:duplicate)} duplicate, " \
        "#{outcomes.count { |outcome| outcome.status == :failed }} failed"
      )
      outcomes
    end
  end
end
