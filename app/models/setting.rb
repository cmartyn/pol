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

    # Whether the agent newsroom (Phase 5) is allowed to run.
    #
    # ENV["AGENTS_DISABLED"] being present is a hard kill switch: it forces
    # false regardless of what's stored in the database, in every
    # environment.
    #
    # An explicit stored value — what the admin toggle writes — always wins
    # over any default, in both directions.
    #
    # With nothing stored, the default depends on environment: true
    # everywhere except development, where it is false. Two dev-server
    # incidents (23 published dispatches, then 74 near-missed) both traced
    # back to this defaulting true with only a per-process ENV var standing
    # between a `rails server` on someone's laptop and the newsroom firing
    # for real. A freshly cloned or reset development database should be
    # unarmed by construction; test and production are unaffected; see
    # Admin::KillSwitchStatus for the three-part display this decides.
    def agents_enabled?
      return false if ENV["AGENTS_DISABLED"].present?

      stored = get(AGENTS_ENABLED_KEY)
      return ActiveModel::Type::Boolean.new.cast(stored) unless stored.nil?

      !Rails.env.development?
    end
  end
end
