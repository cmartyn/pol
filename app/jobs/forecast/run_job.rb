class Forecast::RunJob < ApplicationJob
  queue_as :default

  # A full run takes a couple of seconds and a scrape sweep can finish while
  # one is in flight; two concurrent runs would race each other to be the
  # latest succeeded run, and the loser's numbers would flicker onto the site.
  # The second one steps aside — the polls it would have read are still there
  # for the next run.
  def perform(trigger: :ingest)
    if ModelRun.running.exists?
      Rails.logger.info("Forecast::RunJob: a model run is already in flight; skipping this #{trigger} run")
      return nil
    end

    Forecast::Runner.call(trigger: trigger)
  end
end
