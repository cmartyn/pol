require "test_helper"

class Forecast::PollGeographyTest < ActiveSupport::TestCase
  setup do
    @race = Race.create!(office: :house, state: "TN", district: 9, slug: "house-2026-tn-09", baseline_margin: 45.6)
    @poll = create_poll(race: @race, pollster: pollsters(:beacon_polling),
      field_start: Date.new(2026, 9, 1), field_end: Date.new(2026, 9, 3), results: { dem: 44, rep: 48 })
    @averager = Forecast::Averager.new(as_of: Date.new(2026, 9, 4))
    @policy = Forecast::PollGeography.new
  end

  test "a date and district number alone do not establish the sample's plan" do
    assert @policy.reason(@poll)
    assert_nil @averager.measurement(@poll)
    assert_not @averager.for_race(@race).polled?
  end

  test "a current NYT general election assignment after adoption is accepted" do
    @poll.entry_mode = :nyt
    @poll.raw_payload = { "nyt" => { "rows" => [ { "cycle" => "2026", "state" => "TN", "seat_number" => "9", "stage" => "general" } ] } }
    assert_nil @policy.reason(@poll)
    assert_in_delta(-4, @averager.measurement(@poll).margin, 1e-9)
    @poll.field_start = Date.new(2026, 5, 6)
    assert @policy.reason(@poll), "a field period straddling adoption needs explicit evidence"
    @poll.field_start = nil
    assert @policy.reason(@poll)
  end

  test "explicit evidence accepts new-line samples and refuses old-line samples in every estimation path" do
    @poll.update!(raw_payload: { "district_plan" => { "id" => "tn-2024", "source_url" => "https://example.com/old-sample" } })
    assert @policy.reason(@poll)
    assert_nil @averager.measurement(@poll), "house effects and internals use this same measurement gate"
    assert_not @averager.for_race(@race).polled?
    @poll.raw_payload["district_plan"]["id"] = "tn-120th-2026"
    assert_nil @policy.reason(@poll)
    assert @averager.measurement(@poll)
  end
end
