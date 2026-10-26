require "test_helper"

class Forecast::BaselineComparisonTest < ActiveSupport::TestCase
  # The comparator creates its own repeatable-read, read-only transaction.
  self.use_transactional_tests = false

  test "paired baseline changes do not persist, notify, or change unaffected forecasts" do
    Race.create!(office: :house, state: "TN", district: 9, slug: "house-2026-tn-09", baseline_margin: 45.6)
    before = [ ModelRun.count, Forecast.count, Dispatch.count, GoodJob::Job.count ]
    report = Forecast::BaselineComparison.call(as_of: Date.new(2026, 10, 25), seed: 42, n_sims: 100, require_complete_house: false)
    assert_equal before, [ ModelRun.count, Forecast.count, Dispatch.count, GoodJob::Job.count ]
    report.fetch(:variants).each_value do |variant|
      affected = variant.fetch(:races).find { |row| row[:changed] }
      assert_operator affected.dig(:before, :mu), :>, 40
      assert_in_delta(-19.6440305439 + variant.fetch(:national_env), affected.dig(:after, :mu), 1e-9)
      variant.fetch(:races).reject { |row| row[:changed] }.each do |row|
        assert_equal row[:before], row[:after], row[:race]
      end
    end
    assert_equal 64, report[:input_digest].length
    assert report.dig(:inputs, :polls).first.key?("results")
  end
end
