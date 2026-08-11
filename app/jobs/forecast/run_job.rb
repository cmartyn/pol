class Forecast::RunJob < ApplicationJob
  queue_as :default

  # A full run takes a couple of seconds and a scrape sweep can finish while
  # one is in flight; two concurrent runs would race each other to be the
  # latest succeeded run, and the loser's numbers would flicker onto the site.
  #
  # The guard is not here — it is the partial unique index the runner inserts
  # against, so a job that loses the race finds out by being refused rather
  # than by asking first and being told a stale answer. Stepping aside is not a
  # failure and must not retry: the run that won is producing the numbers this
  # one would have, from the same polls.
  #
  # poll_ids are the polls whose arrival triggered this run (Ingest.after_new_polls!).
  # They are carried through rather than re-derived because the newsroom's
  # reactions have to know which polls are new, and only the sweep knows that.
  # A run that steps aside drops them: the run that won will publish the
  # numbers, but nothing reacts to those particular polls. That is the honest
  # cost of the guard and it is recorded in docs/BUILD_NOTES.md Phase 5.
  def perform(trigger: :ingest, poll_ids: [])
    model_run = Forecast::Runner.call(trigger: trigger)

    # In production the runner records a failure on the run row and returns
    # rather than raising, so a failed run must not be mistaken for a fresh
    # forecast worth writing about.
    Newsroom.after_model_run!(model_run, poll_ids: poll_ids) if model_run&.succeeded?

    model_run
  rescue Forecast::Runner::AlreadyRunning => error
    Rails.logger.info("Forecast::RunJob: #{error.message}; skipping this #{trigger} run")
    nil
  end
end
