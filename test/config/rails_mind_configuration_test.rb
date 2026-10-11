# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "json"
require "rbconfig"

class RailsMindConfigurationTest < Minitest::Test
  INITIALIZER = File.expand_path("../../config/initializers/rails_mind.rb", __dir__)
  SYNTHETIC_KEY = "rm_#{'0' * 64}".freeze
  PROBE = <<~'RUBY'.freeze
    require "json"
    require "rails"
    require "rails_mind"

    # Even a regression cannot send this synthetic observation over the network.
    RailsMind::Transport.define_method(:send_batch) do |_json|
      raise "Network delivery is forbidden in the initializer regression check"
    end

    RailsMind::Transport.define_method(:fetch_sampling_policy) do
      raise "Network policy reads are forbidden in the initializer regression check"
    end

    inherited_enabled = RailsMind.configuration.enabled?
    load ARGV.fetch(0)
    puts JSON.generate(
      inherited_enabled: inherited_enabled,
      enabled: RailsMind.configuration.enabled?,
      credential_cleared: RailsMind.configuration.token.nil?,
      credential_matches_environment: RailsMind.configuration.token == ENV["RAILS_MIND_KEY"],
      collector_present: !RailsMind.client.collector.nil?,
      accepted_test_observation: Rails.env.test? ? RailsMind.track("synthetic_configuration_check") : nil
    )
    RailsMind.shutdown
  RUBY

  def test_inherited_credential_is_explicitly_cleared_in_test
    result = probe("test")
    assert_equal true, result.fetch("inherited_enabled"), "the SDK default must first see the synthetic inherited key"
    assert_equal true, result.fetch("credential_cleared")
    assert_equal false, result.fetch("enabled")
    assert_equal false, result.fetch("collector_present")
    assert_equal false, result.fetch("accepted_test_observation")
  end

  def test_non_test_configuration_preserves_environment_credential
    # Load only Rails and this initializer, not the application or its jobs/mail.
    result = probe("production")
    assert_equal true, result.fetch("inherited_enabled")
    assert_equal true, result.fetch("credential_matches_environment")
    assert_equal true, result.fetch("enabled")
    assert_equal true, result.fetch("collector_present")
    assert_nil result.fetch("accepted_test_observation")
  end

  private

  def probe(environment)
    output, errors, status = Open3.capture3(
      { "RAILS_ENV" => environment, "RAILS_MIND_KEY" => SYNTHETIC_KEY, "RAILS_MIND_ENDPOINT" => "http://127.0.0.1:1" },
      RbConfig.ruby, "-rbundler/setup", "-e", PROBE, INITIALIZER)
    assert status.success?, errors
    JSON.parse(output)
  end
end
