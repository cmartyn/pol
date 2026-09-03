require "test_helper"

class Site::PollFeedTest < ActiveSupport::TestCase
  setup { Poll.destroy_all }

  def arrived(at, field_end: Date.new(2026, 8, 1), **attributes)
    create_poll(pollster: pollsters(:beacon_polling), race: races(:senate_maine),
                field_end: field_end, created_at: at, **attributes)
  end

  test "polls are grouped into days, newest arrival first" do
    older = arrived(Time.zone.local(2026, 8, 18, 9))
    newer_a = arrived(Time.zone.local(2026, 8, 20, 9))
    newer_b = arrived(Time.zone.local(2026, 8, 20, 15))

    days = Site::PollFeed.build(page: 1).days

    assert_equal [ Date.new(2026, 8, 20), Date.new(2026, 8, 18) ], days.map(&:date)
    assert_equal [ newer_b.id, newer_a.id ], days.first.polls.map(&:id)
    assert_equal [ older.id ], days.second.polls.map(&:id)
  end

  # The sweep runs every two hours, so it lands polls after midnight UTC —
  # 8pm Eastern the evening before — several times a week. Grouping those on
  # the database's UTC date would file an 8pm poll under tomorrow and print a
  # heading whose count does not match the rows under it.
  test "days are the reader's days, not the database's UTC days" do
    evening = arrived(Time.zone.local(2026, 8, 20, 20, 30))
    assert_equal Date.new(2026, 8, 21), evening.created_at.utc.to_date, "fixture must straddle UTC midnight"

    days = Site::PollFeed.build(page: 1).days

    assert_equal [ Date.new(2026, 8, 20) ], days.map(&:date)
    assert_equal 1, days.first.total
  end

  # A day bigger than one page — the source switch landed 1,515 polls at once
  # — keeps its true total in the heading on every page it spans, rather than
  # relabelling itself as however many happened to fit.
  test "a day's total counts the whole day even when it spans pages" do
    5.times { |n| arrived(Time.zone.local(2026, 8, 20, 9, n)) }

    feed = Site::PollFeed.build(page: 1, per_page: 2)

    assert_equal 5, feed.days.first.total
    assert_equal 2, feed.days.first.polls.size
    assert_equal 3, feed.pages
    assert_equal 5, feed.total
  end

  test "later pages continue the same ordering without repeating a poll" do
    5.times { |n| arrived(Time.zone.local(2026, 8, 20, 9, n)) }

    seen = (1..3).flat_map { |page| Site::PollFeed.build(page: page, per_page: 2).days.flat_map(&:polls) }.map(&:id)

    assert_equal Poll.model_corpus.newest_ingested.pluck(:id), seen
  end

  test "a page number past the end returns no days rather than raising" do
    arrived(Time.zone.local(2026, 8, 20, 9))

    feed = Site::PollFeed.build(page: 99)

    assert_empty feed.days
    assert_equal 1, feed.total
  end

  # The controller redirects past-the-end pages before building, but a direct
  # caller can still ask. Its "newer" link must land on real rows, not on the
  # next empty page back.
  test "a page past the end points its newer link at the last real page" do
    5.times { |n| arrived(Time.zone.local(2026, 8, 20, 9, n)) }

    feed = Site::PollFeed.build(page: 99, per_page: 2)

    assert_equal 3, feed.pages
    assert_equal 3, feed.previous_page
    assert_nil feed.next_page
  end

  test "last_page is one for an empty corpus and rounds up otherwise" do
    assert_equal 1, Site::PollFeed.last_page(0)
    assert_equal 1, Site::PollFeed.last_page(1)
    assert_equal 1, Site::PollFeed.last_page(Site::PollFeed::PER_PAGE)
    assert_equal 2, Site::PollFeed.last_page(Site::PollFeed::PER_PAGE + 1)
  end

  test "a page number below one is treated as the first page" do
    arrived(Time.zone.local(2026, 8, 20, 9))

    assert_equal 1, Site::PollFeed.build(page: 0).page
    assert_equal 1, Site::PollFeed.build(page: "nonsense").page
    assert_equal 1, Site::PollFeed.build(page: nil).page
  end

  # Whatever shape the query string arrives in — Rack hands over an Array
  # for ?page[]=2 and a Parameters hash for ?page[x]=2 — comes out a page
  # number of at least one.
  test "normalize_page turns any query-string value into a page number" do
    assert_equal 1, Site::PollFeed.normalize_page(nil)
    assert_equal 1, Site::PollFeed.normalize_page("")
    assert_equal 1, Site::PollFeed.normalize_page("nonsense")
    assert_equal 1, Site::PollFeed.normalize_page(-4)
    assert_equal 1, Site::PollFeed.normalize_page([ "2" ])
    assert_equal 1, Site::PollFeed.normalize_page(ActionController::Parameters.new(x: "2"))
    assert_equal 7, Site::PollFeed.normalize_page("7")
    assert_equal 999_999_999, Site::PollFeed.normalize_page(999_999_999)
  end

  test "the retired Wikipedia-scraped rows are left out of both the rows and the totals" do
    arrived(Time.zone.local(2026, 8, 20, 9))
    arrived(Time.zone.local(2026, 8, 20, 10), entry_mode: :scraped)

    feed = Site::PollFeed.build(page: 1)

    assert_equal 1, feed.total
    assert_equal 1, feed.days.first.total
  end

  # The feed lists polls across every race, and the row reaches through
  # race.candidates for its margin and result.candidate for its names — an
  # N+1 on any of them is a query per row, 100 of them a page.
  test "a page costs the same number of queries however many polls are on it" do
    3.times { |n| arrived_with_candidates(Time.zone.local(2026, 8, 20, 9, n)) }
    baseline = count_queries { touch_every_association_on_page(1) }

    3.times { |n| arrived_with_candidates(Time.zone.local(2026, 8, 20, 10, n)) }

    assert_equal baseline, count_queries { touch_every_association_on_page(1) }
  end

  private
    # Results carry candidates on purpose: a nil belongs_to issues no query,
    # so candidate-less results cannot reveal a missing preload.
    def arrived_with_candidates(at)
      poll = arrived(at)
      poll.poll_results.create!(party: :dem, pct: 48.0, candidate: candidates(:maine_dem))
      poll.poll_results.create!(party: :rep, pct: 45.0, candidate: candidates(:maine_rep))
      poll
    end

    # Everything the row partial reads, so a preload the feed forgot shows up
    # as a query here.
    def touch_every_association_on_page(page)
      Site::PollFeed.build(page: page).days.each do |day|
        day.polls.each do |poll|
          poll.pollster
          poll.race&.candidates&.to_a
          poll.poll_results.each { |result| result.candidate }
        end
      end
    end
end
