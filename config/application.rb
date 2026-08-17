require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Pol
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Postgres-backed job backend; see config/initializers/good_job.rb.
    config.active_job.queue_adapter = :good_job

    # Eastern is this site's clock. American election coverage is written and
    # read on it: polls close on it, returns come in on it, and "Tuesday's
    # numbers" means a Tuesday in New York. Running the app on UTC meant every
    # evening between 8pm and midnight ET was already tomorrow as far as
    # Date.current was concerned — which is precisely when a poll lands and a
    # run fires. Newsroom::ZONE pinned Eastern by hand to work around that;
    # this makes it the default rather than the exception.
    #
    # Storage is untouched: config.active_record.default_timezone stays :utc,
    # so every timestamp is still written to Postgres in UTC and only
    # converted on the way out. This setting changes what we read and print,
    # never what we store.
    config.time_zone = "Eastern Time (US & Canada)"

    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
