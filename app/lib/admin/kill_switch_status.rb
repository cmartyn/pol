module Admin
  # The kill switch's three-part display the brief's Settings section wants,
  # shared by the dashboard's compact card and the full settings page:
  # Setting.agents_enabled? already knows how to combine the stored value
  # and the ENV override into one answer — this exposes the parts it
  # combines too, so the admin can show its work instead of only the
  # effective result.
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

    # "not set (defaults to on)" / "on" / "off" — the raw Setting row, read
    # literally rather than through Setting.agents_enabled?'s ENV-aware
    # combination, which is exactly the point: this is the part of the
    # three-part display ENV does NOT affect.
    def stored_label
      return "not set (defaults to on)" if stored.nil?

      ActiveModel::Type::Boolean.new.cast(stored) ? "on" : "off"
    end
  end
end
