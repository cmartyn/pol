require "test_helper"

class Site::HouseTableTest < ActiveSupport::TestCase
  test "builds one row per House race with its forecast and district poll count" do
    rows = Site::HouseTable.build.index_by { |row| row.race.id }

    ny17 = rows.fetch(races(:house_ny_17).id)
    assert_nil ny17.forecast # no forecast fixture for house_ny_17
    assert_equal 0, ny17.poll_count
  end

  test "picks up the latest forecast and a real poll count when they exist" do
    run = model_runs(:model_run_one)
    Forecast.create!(model_run: run, race: races(:house_ny_17), p_dem_win: 0.77, p_rep_win: 0.23, mean_margin: 7.2)
    2.times do |i|
      Poll.create!(
        pollster: pollsters(:beacon_polling), race: races(:house_ny_17), field_end: Date.new(2026, 7, 1 + i),
        sample_size: 400, population: :lv, source_url: "https://example.com/house-table-test/#{i}",
        dedup_digest: "house-table-test-#{i}", entry_mode: :manual
      )
    end

    row = Site::HouseTable.build.find { |r| r.race.id == races(:house_ny_17).id }

    assert_in_delta 0.77, row.forecast.p_dem_win
    assert_equal 2, row.poll_count
  end

  test "orders districts by state then district number" do
    create_house_race("house-table-test-al-02", state: "AL", district: 2)
    create_house_race("house-table-test-al-01", state: "AL", district: 1)

    ordering = Site::HouseTable.build
      .select { |row| row.race.state == "AL" }
      .map { |row| row.race.district }

    assert_equal [ 1, 2 ], ordering
  end

  test "a bounded number of queries regardless of row count (the 435-district page's core risk)" do
    # Deliberately no warm-up call here: an uncounted call immediately
    # before the counted one can make the *second* (identical) query get
    # served from Active Record's query cache and undercount. Measuring cold
    # and busting the cache with real writes before the second measurement
    # (below) keeps both counts honest.
    baseline = count_queries { Site::HouseTable.build }

    5.times { |i| create_house_race("house-table-test-extra-#{i}", state: "ZZ", district: 90 + i) }

    with_extra_rows = count_queries { Site::HouseTable.build }

    assert_equal baseline, with_extra_rows
    assert_operator baseline, :<=, 5
  end

  private
    def create_house_race(slug, state:, district:)
      Race.create!(office: :house, state: state, district: district, slug: slug, cycle: 2026, baseline_margin: 0.0)
    end
end
