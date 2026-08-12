require "test_helper"

class SettingTest < ActiveSupport::TestCase
  test "set then get round-trips a value" do
    Setting.set("some_key", "some_value")
    assert_equal "some_value", Setting.get("some_key")
  end

  test "set updates the existing row instead of creating a duplicate" do
    Setting.set("some_key", "first")
    Setting.set("some_key", "second")

    assert_equal "second", Setting.get("some_key")
    assert_equal 1, Setting.where(key: "some_key").count
  end

  test "get returns the given default when no row exists" do
    assert_nil Setting.get("missing_key")
    assert_equal "fallback", Setting.get("missing_key", default: "fallback")
  end

  # This suite runs under Rails.env == "test", so this pins the default that
  # matters for every other test in the app (and for production, which
  # shares it): outside development, an unset setting still means agents on.
  test "agents_enabled? defaults to true when never set outside development" do
    assert Setting.agents_enabled?
  end

  test "agents_enabled? respects an explicit false stored value" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")
    refute Setting.agents_enabled?
  end

  test "agents_enabled? respects an explicit true stored value" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")
    assert Setting.agents_enabled?
  end

  test "ENV AGENTS_DISABLED forces agents_enabled? false regardless of the stored value" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")
    with_env("AGENTS_DISABLED", "1") { refute Setting.agents_enabled? }
  end

  test "ENV AGENTS_DISABLED forces false even with no stored setting at all" do
    with_env("AGENTS_DISABLED", "1") { refute Setting.agents_enabled? }
  end

  # Final fixes: the arming hazard. Two dev-server incidents (23 published
  # dispatches, then 74 near-missed) both traced back to agents_enabled?
  # defaulting true with only a per-process ENV var standing in the way.
  test "agents_enabled? defaults to false in development when never set" do
    with_rails_env("development") { refute Setting.agents_enabled? }
  end

  test "an explicit stored true value wins over the development default" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")
    with_rails_env("development") { assert Setting.agents_enabled? }
  end

  test "an explicit stored false value wins in development too" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "false")
    with_rails_env("development") { refute Setting.agents_enabled? }
  end

  test "ENV AGENTS_DISABLED forces false in development regardless of the stored value" do
    Setting.set(Setting::AGENTS_ENABLED_KEY, "true")
    with_rails_env("development") do
      with_env("AGENTS_DISABLED", "1") { refute Setting.agents_enabled? }
    end
  end

  private
    # Sets ENV[key] = value for the duration of the block, then restores
    # whatever was there before (including absence).
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
