require "test_helper"

class Ingest::Nyt::SyncTest < ActiveSupport::TestCase
  SENATE_URL = "https://www.nytimes.com/newsgraphics/polls/senate.csv".freeze
  HOUSE_URL = "https://www.nytimes.com/newsgraphics/polls/house.csv".freeze

  setup do
    @senate_body = nyt_csv(
      nyt_matchup_rows +
      nyt_matchup_rows("question_id" => "q-primary", "stage" => "primary") +
      nyt_matchup_rows("question_id" => "q-wyoming", "state" => "WY", "poll_id" => "poll-wy")
    )
    @house_body = nyt_csv(nyt_matchup_rows(
      "office_type" => "U.S. House", "state" => "NY", "seat_number" => "17",
      "question_id" => "q-house", "poll_id" => "poll-house", "pollster" => "Beacon Research",
      dem: { "candidate_name" => "Casey Nolan" },
      rep: { "candidate_name" => "Drew Halloran" }
    ))
  end

  def stub_feed(senate: @senate_body, house: @house_body)
    stub_request(:get, SENATE_URL).to_return(senate.is_a?(Hash) ? senate : { status: 200, body: senate })
    stub_request(:get, HOUSE_URL).to_return(house.is_a?(Hash) ? house : { status: 200, body: house })
  end

  test "a sweep ingests both files and accounts for every question" do
    stub_feed

    outcomes = nil
    assert_difference "Poll.count", 2 do
      assert_difference "ScrapeRun.count", 2 do
        outcomes = Ingest::Nyt::Sync.new.call
      end
    end

    senate, house = outcomes
    # Refused questions are NOT fetched — that is what lets dark? fire.
    assert_equal [ "nyt:senate.csv", :succeeded, 1, 1, 0, 1, 1 ],
                 [ senate.source, senate.status, senate.fetched, senate.created,
                   senate.duplicate, senate.skipped, senate.refused ]
    assert_equal({ "unknown_race" => 1 }, senate.refusals)
    assert_equal [ "nyt:house.csv", :succeeded, 1, 1, 0 ],
                 [ house.source, house.status, house.fetched, house.created, house.refused ]

    poll = Poll.nyt.find_by(nyt_question_id: "question-1")
    assert_equal races(:senate_maine), poll.race
    assert_equal "poll-1", poll.nyt_poll_id
  end

  test "a second sweep of the same content skips parsing entirely — a quiet no-op" do
    stub_feed
    Ingest::Nyt::Sync.new.call

    assert_no_difference [ "Poll.count", "FeedSnapshot.count" ] do
      outcomes = Ingest::Nyt::Sync.new.call

      assert_equal %i[succeeded succeeded], outcomes.map(&:status)
      assert_equal [ 0, 0 ], outcomes.map(&:fetched)
      assert_equal [ 0, 0 ], outcomes.map(&:created)
    end
  end

  test "changed content re-syncs, and already-ingested questions count as duplicates" do
    stub_feed
    Ingest::Nyt::Sync.new.call

    stub_feed(senate: nyt_csv(nyt_matchup_rows(dem: { "pct" => "51" }) +
                              nyt_matchup_rows("question_id" => "q-new", "poll_id" => "poll-new",
                                               "pollster" => "Cardinal Research", "pollster_id" => "pollster-uuid-2")))
    outcomes = Ingest::Nyt::Sync.new.call

    senate = outcomes.first
    # question-1's toplines changed but its id is known — content updates do
    # not re-ingest; only q-new is created.
    assert_equal [ 2, 1, 1 ], [ senate.fetched, senate.created, senate.duplicate ]
  end

  test "snapshots are kept per file and only when content changes" do
    stub_feed

    assert_difference "FeedSnapshot.count", 2 do
      Ingest::Nyt::Sync.new.call
    end

    changed = nyt_csv(nyt_matchup_rows(dem: { "pct" => "51" }))
    stub_feed(senate: changed)

    assert_difference "FeedSnapshot.count", 1 do
      Ingest::Nyt::Sync.new.call
    end

    assert_equal changed, FeedSnapshot.latest_for("nyt:senate.csv").csv_body
  end

  test "a 304 is a clean, quiet run" do
    stub_feed(senate: { status: 304 }, house: { status: 304 })

    outcomes = Ingest::Nyt::Sync.new.call

    assert_equal %i[succeeded succeeded], outcomes.map(&:status)
    assert_equal [ 0, 0 ], outcomes.map(&:fetched)
  end

  test "a feed that stops changing trips the staleness alarm" do
    stub_feed
    Ingest::Nyt::Sync.new.call

    travel Pol::Params.fetch!(:feed, :staleness_alarm_days).days + 1.hour do
      stub_feed
      outcomes = Ingest::Nyt::Sync.new.call

      assert_equal %i[partial partial], outcomes.map(&:status)
      assert_match(/unchanged for \d+ days/, outcomes.first.error)
    end
  end

  test "one file failing leaves the other's ingest untouched" do
    stub_feed(senate: { status: 500 })

    outcomes = Ingest::Nyt::Sync.new.call

    senate, house = outcomes
    assert_equal :failed, senate.status
    assert_match(/HTTP 500/, senate.error)
    assert_equal :succeeded, house.status
    assert_equal 1, house.created
    assert_equal 1, Poll.nyt.count
  end

  test "created ids reach the model-run seam once, across both files" do
    stub_feed

    recording(Ingest, :after_new_polls!) do |calls|
      Ingest::Nyt::Sync.new.call

      assert_equal 1, calls.size
      assert_equal Poll.nyt.order(:id).pluck(:id), calls.first.first.sort
    end
  end

  test "refusing everything is a dark run the alarm can see" do
    stub_feed(senate: nyt_csv(nyt_matchup_rows("state" => "WY")), house: nyt_csv([]))

    Ingest::Nyt::Sync.new.call

    run = ScrapeRun.find_by(source: "nyt:senate.csv")
    assert_equal 0, run.fetched_count
    assert_equal 1, run.refused_count
    assert_predicate run, :dark?
    assert_predicate run, :refusal_alarm?
  end

  test "an unparseable body leaves no snapshot to hide behind" do
    stub_feed(senate: %(a,b\n"unclosed,1\n"x",2), house: nyt_csv([]))

    outcomes = Ingest::Nyt::Sync.new.call

    assert_equal :failed, outcomes.first.status
    assert_nil FeedSnapshot.latest_for("nyt:senate.csv")

    # The next sweep is not stuck behind a 304 of the bad body: the good
    # content ingests normally.
    stub_feed
    assert_difference "Poll.count", 2 do
      Ingest::Nyt::Sync.new.call
    end
  end

  test "an unexpected error fails one file and leaves the other untouched" do
    stub_request(:get, SENATE_URL).to_raise(OpenSSL::SSL::SSLError.new("handshake"))
    stub_request(:get, HOUSE_URL).to_return(status: 200, body: @house_body)

    outcomes = Ingest::Nyt::Sync.new.call

    assert_equal :failed, outcomes.first.status
    assert_match(/SSLError/, outcomes.first.error)
    assert_equal 1, outcomes.last.created
  end
end
