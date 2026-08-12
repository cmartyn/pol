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

  # Final fixes: in development, with nothing stored, the development
  # default (Setting.agents_enabled?) is the reason agents are off — the
  # three-part display should name that reason rather than just say "off"
  # the way it would for an ENV override or an explicit false.
  test "development_default? and stored_label name the development default as the reason, in development with nothing stored" do
    with_rails_env("development") do
      status = Admin::KillSwitchStatus.call

      assert status.development_default?
      assert_equal "not set (defaults to off in development)", status.stored_label
      assert_not status.effective?
      assert_not status.env_override?
    end
  end

  test "development_default? is false once a value is explicitly stored, even in development" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")

    with_rails_env("development") do
      status = Admin::KillSwitchStatus.call

      assert_not status.development_default?
      assert_equal "on", status.stored_label
      assert status.effective?
    end
  end

  test "development_default? is false when ENV is overriding, even in development with nothing stored" do
    with_rails_env("development") do
      with_env("AGENTS_DISABLED", "1") do
        status = Admin::KillSwitchStatus.call

        assert_not status.development_default?, "the ENV override is the reason here, not the development default"
        assert status.env_override?
        assert_not status.effective?
      end
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
