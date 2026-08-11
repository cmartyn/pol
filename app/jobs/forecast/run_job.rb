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
  def perform(trigger: :ingest)
    Forecast::Runner.call(trigger: trigger)
  rescue Forecast::Runner::AlreadyRunning => error
    Rails.logger.info("Forecast::RunJob: #{error.message}; skipping this #{trigger} run")
    nil
  end
end
