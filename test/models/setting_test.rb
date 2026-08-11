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

  test "agents_enabled? defaults to true when never set" do
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
end
