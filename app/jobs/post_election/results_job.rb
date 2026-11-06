class PostElection::ResultsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency
  queue_as :election_night
  self.good_job_labels = [ "post-election-results" ]
  good_job_concurrency_rule(total_limit: 1, label: "post-election-results")

  def perform
    return unless ForecastArchive.active?

    PostElection::Sync.new.call
  rescue ElectionNight::Store::Busy
    Rails.logger.info("Post-election results sweep already running")
  end
end
