class ElectionNight::SweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :election_night
  # A sweep may outlast its cron interval. Count both queued and running jobs
  # so a single-thread worker does not accumulate stale sweeps behind it.
  self.good_job_labels = [ "election-night-sweep" ]
  good_job_concurrency_rule(total_limit: 1, label: "election-night-sweep")

  def perform
    return if ForecastArchive.active?
    return unless ENV["ELECTION_NIGHT_ENABLED"] == "true"
    store = ElectionNight::Store.new
    unless store.read("prior")
      Rails.logger.info("ElectionNight::SweepJob: waiting for a frozen pre-election prior; skipping scheduled sweep")
      return
    end
    ElectionNight::Runner.new(store: store).call
  rescue ElectionNight::Store::Busy => error
    # A slow sweep can outlast the cron interval. Its successor should finish
    # successfully rather than become a failed job that repeatedly retries.
    Rails.logger.info("ElectionNight::SweepJob: #{error.message}; skipping overlapping sweep")
    nil
  end
end
