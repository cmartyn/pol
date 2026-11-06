require "test_helper"

class PostElection::CivicReportTest < ActiveSupport::TestCase
  setup do
    @data = JSON.parse(file_fixture("election_night/northeast/civic_al_house.json").read)
    @data.merge!("last_updated" => "2026-11-05T16:00:00Z", "is_disputed" => false, "called_at" => nil)
    @data["candidates"].each { |c| c.merge!("winner" => false, "votes" => 120) }
    @data["candidates"].first["votes"] = 300
  end

  test "only an explicit winner produces a call, and only the publisher can supply its time" do
    @data["percent_reporting"] = 100
    assert_equal "uncalled", report.dig(:provider_call, "status")
    @data["candidates"].last["winner"] = true
    assert_equal @data["candidates"].last["name"], report.dig(:provider_call, "winner", "name")
    assert_nil report.dig(:provider_call, "decided_at")
    @data["called_at"] = "2026-11-04T03:00:00Z"
    assert_equal @data["called_at"], report.dig(:provider_call, "decided_at")
    @data["is_disputed"] = true
    assert_equal "under_review", report.dig(:provider_call, "status")
    assert_nil report.dig(:provider_call, "winner")
  end

  test "a missing flag, test election, different district and invalid counts cannot manufacture a winner" do
    @data["candidates"].last.delete("winner")
    assert_nil report.fetch(:provider_call)
    @data["test_data"] = true
    assert_raises(ElectionNight::Sources::Base::InvalidData) { report }
    @data["test_data"] = false
    assert_raises(ElectionNight::Sources::Base::InvalidData) { report("AL-01") }
    @data["candidates"].last["votes"] = -1
    assert_raises(ElectionNight::Sources::Base::InvalidData) { report }
  end

  private
    def report(key = "AL-02")
      PostElection::CivicReport.new(state: "AL").read(@data, race_key: key, url: "https://civicapi.org/",
        fetched_at: Time.iso8601("2026-11-05T16:01:00Z"))
    end
end
