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
end
