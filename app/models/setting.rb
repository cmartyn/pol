class Setting < ApplicationRecord
  AGENTS_ENABLED_KEY = "agents_enabled"

  class << self
    # Setting.get("some_key", default: "fallback") => the stored value for
    # that key, or the given default if no row exists (or its value is nil).
    def get(key, default: nil)
      find_by(key: key.to_s)&.value || default
    end

    # Setting.set("some_key", "value") => creates or updates the row for key.
    def set(key, value)
      setting = find_or_initialize_by(key: key.to_s)
      setting.value = value
      setting.save!
      setting
    end

    # Whether the agent newsroom (Phase 5) is allowed to run. Defaults to
    # true when no setting has ever been stored. ENV["AGENTS_DISABLED"]
    # being present is a hard kill switch: it forces false regardless of
    # what's stored in the database.
    def agents_enabled?
      return false if ENV["AGENTS_DISABLED"].present?

      stored = get(AGENTS_ENABLED_KEY)
      stored.nil? || ActiveModel::Type::Boolean.new.cast(stored)
    end
  end
end
