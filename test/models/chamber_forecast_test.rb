require "test_helper"

class ChamberForecastTest < ActiveSupport::TestCase
  test "chamber enum round-trips every value" do
    ChamberForecast.chambers.each_key do |value|
      forecast = ChamberForecast.new(chamber: value)
      assert_equal value, forecast.chamber
    end
  end

  test "unique index prevents two chamber_forecasts for the same model_run and chamber" do
    duplicate = ChamberForecast.new(
      model_run: model_runs(:model_run_one), chamber: :senate,
      p_dem_control: 0.5, p_rep_control: 0.5, mean_dem_seats: 218.0
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) do
        duplicate.save(validate: false)
      end
    end
  end
end
