require "test_helper"

class FeedSnapshotTest < ActiveSupport::TestCase
  test "record! stores gzipped content that round-trips" do
    snapshot = FeedSnapshot.record!(source: "nyt:senate.csv", body: "a,b\n1,2\n")

    assert_equal "a,b\n1,2\n", snapshot.csv_body
    assert_not_equal snapshot.csv_body, snapshot.body
  end

  test "identical content is stored once; changed content again" do
    assert FeedSnapshot.record!(source: "nyt:senate.csv", body: "same")
    assert_nil FeedSnapshot.record!(source: "nyt:senate.csv", body: "same")
    assert FeedSnapshot.record!(source: "nyt:senate.csv", body: "different")
    assert_equal 2, FeedSnapshot.for_source("nyt:senate.csv").count
  end

  test "the same content under another source is its own snapshot" do
    FeedSnapshot.record!(source: "nyt:senate.csv", body: "same")

    assert FeedSnapshot.record!(source: "nyt:house.csv", body: "same")
  end

  test "latest_for reads the newest fetch" do
    FeedSnapshot.record!(source: "nyt:senate.csv", body: "old", fetched_at: 2.days.ago)
    FeedSnapshot.record!(source: "nyt:senate.csv", body: "new", fetched_at: 1.hour.ago)

    assert_equal "new", FeedSnapshot.latest_for("nyt:senate.csv").csv_body
  end
end
