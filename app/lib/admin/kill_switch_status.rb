module Admin
  # The kill switch's three-part display the brief's Settings section wants,
  # shared by the dashboard's compact card and the full settings page:
  # Setting.agents_enabled? already knows how to combine the stored value,
  # the ENV override, and (final fixes pass) the development-only default
  # into one answer — this exposes the parts it combines too, so the admin
  # can show its work instead of only the effective result.
  class KillSwitchStatus
    ENV_VAR = "AGENTS_DISABLED".freeze

    def self.call
      new(
        stored: Setting.get(Setting::AGENTS_ENABLED_KEY),
        env_override: ENV[ENV_VAR].present?,
        effective: Setting.agents_enabled?
      )
    end

    attr_reader :stored, :env_override, :effective

    def initialize(stored:, env_override:, effective:)
      @stored = stored
      @env_override = env_override
      @effective = effective
    end

    alias_method :env_override?, :env_override
    alias_method :effective?, :effective

    # True when nothing is stored, ENV isn't forcing anything, and the
    # reason `effective` is false is purely Setting.agents_enabled?'s
    # development default — not an explicit admin choice, and not the ENV
    # kill switch. Lets the show page name the actual reason instead of
    # just reporting "off" with no explanation.
    def development_default?
      stored.nil? && !env_override? && Rails.env.development?
    end

    # "not set (defaults to on)" / "not set (defaults to off in
    # development)" / "on" / "off" — the raw Setting row, read literally
    # rather than through Setting.agents_enabled?'s ENV-and-environment-aware
    # combination, which is exactly the point: this is the part of the
    # three-part display that neither ENV nor the development default
    # changes once something is actually stored.
    def stored_label
      return "not set (defaults to #{development_default? ? "off in development" : "on"})" if stored.nil?

      ActiveModel::Type::Boolean.new.cast(stored) ? "on" : "off"
    end
  end
end
