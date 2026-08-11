# Everything that turns the outside world (today: Wikipedia) into rows in our
# tables. The three entry modes the schema knows about — scraped, manual and
# csv — all converge on Ingest::RecordPoll.
module Ingest
  # Called once at the end of a full scrape sweep, with the ids of the polls
  # that were actually created. The forecast hangs off this seam so that
  # ingestion never has to know what a model run is: new polls go in, a run is
  # queued, and the scraper's job is done.
  #
  # The ids travel with the run rather than being re-derived later because
  # "which polls arrived in this sweep" is knowledge only the sweep has — by
  # the time the newsroom writes a reaction, a poll created two minutes ago and
  # one created two hours ago look identical in the table. Forecast::RunJob
  # carries them through to Newsroom.after_model_run! once the run succeeds.
  def self.after_new_polls!(poll_ids)
    poll_ids = Array(poll_ids)
    return if poll_ids.empty?

    Rails.logger.info("Ingest: #{poll_ids.size} new poll(s); queueing a forecast run")
    Forecast::RunJob.perform_later(trigger: :ingest, poll_ids: poll_ids)
  end
end
