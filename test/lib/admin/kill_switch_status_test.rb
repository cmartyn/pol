require "test_helper"

class Admin::KillSwitchStatusTest < ActiveSupport::TestCase
  test "stored_label reads not set when the setting has never been written" do
    status = Admin::KillSwitchStatus.call
    assert_nil status.stored
    assert_equal "not set (defaults to on)", status.stored_label
    assert status.effective?
    assert_not status.env_override?
  end

  test "stored_label reflects an explicit false value" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")
    status = Admin::KillSwitchStatus.call

    assert_equal "off", status.stored_label
    assert_not status.effective?
  end

  test "stored_label reflects an explicit true value" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")
    status = Admin::KillSwitchStatus.call

    assert_equal "on", status.stored_label
    assert status.effective?
  end

  test "env_override is true whenever AGENTS_DISABLED is present, independent of the stored value" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")
    with_env("AGENTS_DISABLED", "1") do
      status = Admin::KillSwitchStatus.call

      assert status.env_override?
      assert_equal "on", status.stored_label # the stored value itself is unaffected
      assert_not status.effective? # but the effective result is forced off
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
end
