require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "show renders the three-part display: stored, env, effective" do
    get admin_settings_path

    assert_response :success
    assert_select "[data-testid='admin-kill-switch-stored']", text: "not set (defaults to on)"
    assert_select "[data-testid='admin-kill-switch-env']", text: "Not set"
    assert_select "[data-testid='admin-kill-switch-effective']", text: "Agents ON"
  end

  test "show reflects an explicit stored false value" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")
    get admin_settings_path
    assert_select "[data-testid='admin-kill-switch-stored']", text: "off"
    assert_select "[data-testid='admin-kill-switch-effective']", text: "Agents OFF"
  end

  test "update flips the stored value from unset (on) to off" do
    patch admin_settings_path
    assert_redirected_to admin_settings_path
    refute ActiveModel::Type::Boolean.new.cast(Setting.get(Setting::AGENTS_ENABLED_KEY))
  end

  test "update flips the stored value back from off to on" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")
    patch admin_settings_path
    assert ActiveModel::Type::Boolean.new.cast(Setting.get(Setting::AGENTS_ENABLED_KEY))
  end

  test "ENV override displays as present (name only) and disables the toggle" do
    with_env("AGENTS_DISABLED", "1") do
      get admin_settings_path

      assert_select "[data-testid='admin-kill-switch-env']", text: /Present/
      assert_select "[data-testid='admin-kill-switch-env']", text: /AGENTS_DISABLED/
      assert_select "[data-testid='admin-kill-switch-env']", text: /1/, count: 0 # the value itself is never shown
      assert_select "[data-testid='admin-kill-switch-toggle-disabled']"
      assert_select "[data-testid='admin-kill-switch-toggle']", count: 0
    end
  end

  test "update refuses to flip the stored value while ENV forces agents off" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")

    with_env("AGENTS_DISABLED", "1") do
      patch admin_settings_path
      assert_redirected_to admin_settings_path
    end

    assert_equal "true", Setting.get(Setting::AGENTS_ENABLED_KEY)
  end

  # Final fixes: the arming hazard. In development, with nothing stored, the
  # development default is the reason agents are off — not an explicit
  # choice, not ENV — and the page should say so rather than just showing
  # "off" with no explanation.
  test "show names the development default as the reason when it is what is deciding" do
    with_rails_env("development") do
      get admin_settings_path

      assert_select "[data-testid='admin-kill-switch-stored']", text: "not set (defaults to off in development)"
      assert_select "[data-testid='admin-kill-switch-effective']", text: "Agents OFF"
      assert_select "[data-testid='admin-kill-switch-dev-default-explanation']"
      # Still a live toggle, unlike the ENV-override case — an admin can
      # turn it on for this database.
      assert_select "[data-testid='admin-kill-switch-toggle']"
      assert_select "[data-testid='admin-kill-switch-toggle-disabled']", count: 0
    end
  end

  test "show does not show the development-default explanation once a value is stored" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")

    with_rails_env("development") do
      get admin_settings_path

      assert_select "[data-testid='admin-kill-switch-stored']", text: "on"
      assert_select "[data-testid='admin-kill-switch-effective']", text: "Agents ON"
      assert_select "[data-testid='admin-kill-switch-dev-default-explanation']", count: 0
    end
  end

  # The regression this guards: the update action used to assume "currently
  # stored" defaults to true (a hardcoded `default: "true"`), so clicking
  # "Turn agents on" against an unset development default recomputed
  # "currently on" from that stale assumption and stored *false* — leaving
  # agents off with the button still reading "Turn agents on". Flipping
  # against Setting.agents_enabled? instead fixes it.
  test "update turns agents on from the development default via the toggle" do
    with_rails_env("development") do
      assert_not Setting.agents_enabled?, "sanity check: the development default is off"

      patch admin_settings_path
      assert_redirected_to admin_settings_path

      assert ActiveModel::Type::Boolean.new.cast(Setting.get(Setting::AGENTS_ENABLED_KEY))
      assert Setting.agents_enabled?
    end
  end

  private
    def with_env(key, value)
      original = ENV[key]
      ENV[key] = value
      yield
    ensure
      if original.nil?
        ENV.delete(key)
      else
        ENV[key] = original
      end
    end

    # Runs the block with Rails.env swapped to another environment name, then
    # restores it. Each parallel test worker is its own process, so this
    # can't leak into other tests running concurrently.
    def with_rails_env(name)
      original = Rails.env
      Rails.env = name
      yield
    ensure
      Rails.env = original
    end
end
