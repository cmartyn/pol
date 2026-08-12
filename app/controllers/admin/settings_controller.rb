module Admin
  # The kill switch page — the one control surface for Setting.agents_enabled?,
  # shown as the three parts that combine into it (Admin::KillSwitchStatus):
  # the stored value, whether ENV is overriding it, and the effective result.
  class SettingsController < BaseController
    def show
      @kill_switch = KillSwitchStatus.call
    end

    # Flips the STORED value (Setting.set) against the current EFFECTIVE one
    # — not a hardcoded assumption of what's stored, because since the final
    # fixes pass that assumption depends on environment (Setting.
    # agents_enabled? defaults to false in development, true elsewhere) and
    # a stale hardcoded default here would silently un-flip itself: "Turn
    # agents on" against an unset development default would have recomputed
    # "currently on" from the old hardcoded true, then stored false, leaving
    # agents off with the button still reading "Turn agents on". ENV is
    # already known absent at this point (see the guard above), so
    # Setting.agents_enabled? here is exactly the stored-or-default value
    # with no ENV interference to account for.
    #
    # When ENV is forcing agents off, the toggle is rendered
    # disabled-with-explanation on the show page; this is the server-side
    # half of that guard, refusing the flip rather than silently changing a
    # stored value the ENV override would keep masking anyway.
    def update
      if ENV[KillSwitchStatus::ENV_VAR].present?
        redirect_to admin_settings_path, alert: "#{KillSwitchStatus::ENV_VAR} is set in the environment — the stored value can't override it."
        return
      end

      Setting.set(Setting::AGENTS_ENABLED_KEY, (!Setting.agents_enabled?).to_s)

      redirect_to admin_settings_path, notice: "Agents #{Setting.agents_enabled? ? "enabled" : "disabled"}."
    end
  end
end
