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
    # Only polls the model actually reads get to queue a run — and, through
    # it, a newsroom reaction. The Wikipedia sweep keeps writing scraped
    # rows as the warm fallback, and without this filter every scraped twin
    # of a feed poll would trigger a run that reproduces the same numbers
    # and a published dispatch about a poll no public surface lists.
    poll_ids = Poll.model_corpus.where(id: Array(poll_ids)).pluck(:id)
    return if poll_ids.empty?

    Rails.logger.info("Ingest: #{poll_ids.size} new poll(s); queueing a forecast run")
    Forecast::RunJob.perform_later(trigger: :ingest, poll_ids: poll_ids)
  end
end
