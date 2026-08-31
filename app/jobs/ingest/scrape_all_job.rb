module Ingest
  # The scheduled sweep — weekly and dry since the NYT feed became the
  # corpus (see config/initializers/good_job.rb and scrape.write_enabled).
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
