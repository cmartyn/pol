# Everything that turns the outside world (today: Wikipedia) into rows in our
# tables. The three entry modes the schema knows about — scraped, manual and
# csv — all converge on Ingest::RecordPoll.
module Ingest
  # Called once at the end of a full scrape sweep, with the number of polls
  # that were actually created. The forecast hangs off this seam so that
  # ingestion never has to know what a model run is: new polls go in, a run is
  # queued, and the scraper's job is done.
  def self.after_new_polls!(count)
    Rails.logger.info("Ingest: #{count} new poll(s); queueing a forecast run")
    Forecast::RunJob.perform_later(trigger: :ingest)
  end
end
