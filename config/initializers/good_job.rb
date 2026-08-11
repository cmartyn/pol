# GoodJob is our Postgres-backed Active Job backend (queue_adapter is set in
# config/application.rb). No Redis, no Solid Queue, no additional services.
Rails.application.configure do
  # Cron is enabled here but the schedule starts empty. Phase 2 (Wikipedia
  # ingestion) and Phase 5 (agent newsroom) add their entries to this hash.
  config.good_job.enable_cron = true
  config.good_job.cron = {}

  # Run the job executor in-process in development so `bin/dev` doesn't need
  # a separate worker process. Production runs a dedicated worker instead
  # (`bundle exec good_job start`), started as its own process/service.
  config.good_job.execution_mode = :async if Rails.env.development?

  # The dashboard (mountable engine) is intentionally not wired up yet;
  # it arrives with the admin namespace in Phase 6.
end
