# GoodJob is our Postgres-backed Active Job backend (queue_adapter is set in
# config/application.rb). No Redis, no Solid Queue, no additional services.
Rails.application.configure do
  # The cadence is the one in config/model_params.yml, read straight from the
  # file rather than through Pol::Params: config initializers run before Rails
  # adds app/ to the autoload paths, so no application constant is reachable
  # here yet. A test asserts this entry still matches Pol::Params, so the two
  # cannot drift.
  cadence_hours = YAML.safe_load_file(Rails.root.join("config/model_params.yml")).fetch("scrape").fetch("cadence_hours")

  # The two daily entries carry an explicit timezone as fugit's sixth cron
  # field (good_job parses cron with fugit, which reads a trailing zone name
  # and resolves DST for it). Without it the schedule would follow the
  # server's clock, and an election site whose morning brief lands at 3am
  # half the year is a bug that only shows up after a deploy to a UTC box.
  # These are publication times rather than model parameters, so unlike the
  # scrape cadence they are literals here — with a test pinning both.
  config.good_job.enable_cron = true
  config.good_job.cron = {
    pol_scrape: {
      cron: "0 */#{cadence_hours} * * *",
      class: "Ingest::ScrapeAllJob",
      description: "Sweep every Wikipedia poll source and ingest new polls"
    },
    # Ingestion queues a run whenever it finds new polls, so on a busy day the
    # model runs often — but on a quiet day nothing re-ran it at all, and the
    # site's "as of" timestamp aged while the forecast sat still. This is the
    # floor: one run every morning, half an hour before the brief is written,
    # so the brief always has same-day numbers to work from.
    pol_daily_model: {
      cron: "30 6 * * * America/New_York",
      class: "Forecast::RunJob",
      kwargs: { trigger: :cron },
      description: "Daily forecast run — the floor under ingest-triggered runs"
    },
    pol_daily_brief: {
      cron: "0 7 * * * America/New_York",
      class: "Newsroom::DailyBriefJob",
      description: "Write the morning national brief"
    }
  }

  # Run the job executor in-process in development so `bin/dev` doesn't need
  # a separate worker process. Production runs a dedicated worker instead
  # (`bundle exec good_job start`), started as its own process/service.
  config.good_job.execution_mode = :async if Rails.env.development?

  # The dashboard is mounted at /admin/good_job (config/routes.rb) and must
  # be gated by the exact same session cookie the rest of /admin uses, not a
  # second auth system bolted on beside it. GoodJob's own README documents
  # this `ActiveSupport.on_load(:good_job_application_controller)` hook as
  # the supported extension point for custom authentication — GoodJob::
  # ApplicationController is a plain ActionController::Base subclass, so
  # `cookies` and the app's own signed session cookie are both right here.
  #
  # Session.from_signed_cookie is the exact lookup Authentication#
  # find_session_by_cookie uses, so a request the rest of /admin would
  # accept is accepted here too, and nothing else is. An unauthenticated
  # request gets a plain 404 (matching the README's own suggested
  # ActionController::RoutingError-as-"Not Found" behavior) rather than a
  # redirect: this mount has no route helpers of its own reaching back into
  # the host app's session routes, and "the page doesn't exist" is a safer
  # default for an internal ops dashboard than hinting at where to sign in.
  ActiveSupport.on_load(:good_job_application_controller) do
    before_action do
      head :not_found unless Session.from_signed_cookie(cookies)&.user
    end
  end
end
