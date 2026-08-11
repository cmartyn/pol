# GoodJob is our Postgres-backed Active Job backend (queue_adapter is set in
# config/application.rb). No Redis, no Solid Queue, no additional services.
Rails.application.configure do
  # Phase 5 (agent newsroom) adds its entries to this hash.
  #
  # The cadence is the one in config/model_params.yml, read straight from the
  # file rather than through Pol::Params: config initializers run before Rails
  # adds app/ to the autoload paths, so no application constant is reachable
  # here yet. A test asserts this entry still matches Pol::Params, so the two
  # cannot drift.
  cadence_hours = YAML.safe_load_file(Rails.root.join("config/model_params.yml")).fetch("scrape").fetch("cadence_hours")

  config.good_job.enable_cron = true
  config.good_job.cron = {
    pol_scrape: {
      cron: "0 */#{cadence_hours} * * *",
      class: "Ingest::ScrapeAllJob",
      description: "Sweep every Wikipedia poll source and ingest new polls"
    }
  }

  # Run the job executor in-process in development so `bin/dev` doesn't need
  # a separate worker process. Production runs a dedicated worker instead
  # (`bundle exec good_job start`), started as its own process/service.
  config.good_job.execution_mode = :async if Rails.env.development?

  # The dashboard (mountable engine) is intentionally not wired up yet;
  # it arrives with the admin namespace in Phase 6.
end
