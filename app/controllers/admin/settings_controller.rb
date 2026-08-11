module Admin
  # The kill switch page — the one control surface for Setting.agents_enabled?,
  # shown as the three parts that combine into it (Admin::KillSwitchStatus):
  # the stored value, whether ENV is overriding it, and the effective result.
  class SettingsController < BaseController
    def show
      @kill_switch = KillSwitchStatus.call
    end

    # Flips the STORED value (Setting.set) — not the effective one, which
    # ENV can force regardless of what's stored. When ENV is forcing agents
    # off, the toggle is rendered disabled-with-explanation on the show
    # page; this is the server-side half of that guard, refusing the flip
    # rather than silently changing a stored value the ENV override would
    # keep masking anyway.
    def update
      if ENV[KillSwitchStatus::ENV_VAR].present?
        redirect_to admin_settings_path, alert: "#{KillSwitchStatus::ENV_VAR} is set in the environment — the stored value can't override it."
        return
      end

      currently_stored = ActiveModel::Type::Boolean.new.cast(Setting.get(Setting::AGENTS_ENABLED_KEY, default: "true"))
      Setting.set(Setting::AGENTS_ENABLED_KEY, (!currently_stored).to_s)

      redirect_to admin_settings_path, notice: "Agents #{Setting.agents_enabled? ? "enabled" : "disabled"}."
    end
  end
end
