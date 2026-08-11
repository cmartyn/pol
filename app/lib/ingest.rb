# Everything that turns the outside world (today: Wikipedia) into rows in our
# tables. The three entry modes the schema knows about — scraped, manual and
# csv — all converge on Ingest::RecordPoll.
module Ingest
  # Called once at the end of a full scrape sweep, with the number of polls
  # that were actually created. Phase 3 hangs the forecast run off this seam so
  # that ingestion never has to know what a model run is.
  def self.after_new_polls!(count)
    # TODO-PHASE-3: enqueue model run
    Rails.logger.info("Ingest: #{count} new poll(s); no downstream consumer wired up yet")
    nil
  end
end
