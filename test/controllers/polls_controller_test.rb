require "test_helper"

class PollsControllerTest < ActionDispatch::IntegrationTest
  test "the feed lists every poll the model reads" do
    get polls_path
    assert_response :success

    assert_select "[data-testid='poll-feed-row']", count: Poll.model_corpus.count
  end

  # The distinction this page exists for. A poll fielded in May that reaches
  # us today is today's news; a poll fielded yesterday that we already had is
  # not. Ordering by field_end — what Poll.recent_first does, and what every
  # race page wants — would put them the other way round.
  test "polls are ordered by when they arrived, not by when they were fielded" do
    Poll.destroy_all
    late_arrival = create_poll(pollster: pollsters(:beacon_polling), race: races(:senate_maine),
                               field_end: Date.new(2026, 5, 1), created_at: 1.hour.ago)
    early_arrival = create_poll(pollster: pollsters(:cardinal_research), race: races(:senate_maine),
                                field_end: Date.new(2026, 8, 1), created_at: 3.days.ago)

    get polls_path

    ids = css_select("[data-testid='poll-feed-row']").map { |row| row["data-poll-id"].to_i }
    assert_equal [ late_arrival.id, early_arrival.id ], ids
  end

  # The retired Wikipedia rows are kept for provenance and read by nothing.
  # Listing them here would claim the model sees polls it does not, and would
  # show each feed poll twice wherever the two sources overlap.
  test "the retired Wikipedia-scraped rows are not in the feed" do
    scraped = create_poll(pollster: pollsters(:beacon_polling), race: races(:senate_maine),
                          field_end: Date.new(2026, 8, 2), entry_mode: :scraped)

    get polls_path

    assert_select "[data-testid='poll-feed-row'][data-poll-id='#{scraped.id}']", count: 0
    assert_select "[data-testid='poll-feed-row']", count: Poll.model_corpus.count
  end

  test "the feed says in words which polls it is showing and which it leaves out" do
    get polls_path

    assert_select "[data-testid='poll-feed-scope-note']", text: /every poll this model reads/i
  end

  test "a row carries the poll's pollster, race, field dates, sample, results, margin and source" do
    poll = polls(:maine_poll_one)

    get polls_path

    assert_select "[data-testid='poll-feed-row'][data-poll-id='#{poll.id}']" do
      assert_select "*", text: /Beacon Polling/
      assert_select "a[href='#{race_path(races(:senate_maine).slug)}']", text: /Maine Senate/
      assert_select "[data-testid='poll-feed-dates']", text: /Jul 10.*Jul 14, 2026/
      assert_select "[data-testid='poll-feed-sample']", text: /812/
      assert_select "[data-testid='poll-feed-sample']", text: /lv/i
      assert_select "[data-testid='poll-feed-results']", text: /Jordan Ellis/
      assert_select "[data-testid='poll-feed-results']", text: /47\.5%/
      assert_select "[data-testid='poll-feed-margin']", text: /D\+3\.5/
      assert_select "a[data-testid='poll-feed-source'][href='#{poll.source_url}']"
    end
  end

  # A generic-ballot poll has no race to take its sides from, but it does have
  # a D and an R — reporting no margin for it would be a shrug where a number
  # exists.
  test "a generic-ballot poll is labelled as such and still shows its margin" do
    poll = polls(:generic_ballot_poll)

    get polls_path

    assert_select "[data-testid='poll-feed-row'][data-poll-id='#{poll.id}']" do
      assert_select "[data-testid='poll-feed-race']", text: /Generic ballot/
      assert_select "[data-testid='poll-feed-margin']", text: /D\+2\.0/
    end
  end

  test "rows sit under a heading for the day they arrived" do
    Poll.destroy_all
    create_poll(pollster: pollsters(:beacon_polling), race: races(:senate_maine),
                field_end: Date.new(2026, 8, 1), created_at: Time.utc(2026, 8, 20, 12))
    2.times do |n|
      create_poll(pollster: pollsters(:cardinal_research), race: races(:senate_maine),
                  field_end: Date.new(2026, 8, 2), created_at: Time.utc(2026, 8, 18, 12 + n))
    end

    get polls_path

    headings = css_select("[data-testid='poll-feed-day']").map { |cell| cell.text.squish }
    assert_equal 2, headings.size
    assert_match(/Arrived August 20, 2026/, headings.first)
    assert_match(/1 poll\b/, headings.first)
    assert_match(/Arrived August 18, 2026/, headings.second)
    assert_match(/2 polls/, headings.second)
  end

  # The site-wide internals toggle works off this attribute and this badge.
  # A feed that dropped them would show partisan-sponsored polls as though
  # they were in the published average.
  test "a partisan-sponsored poll is flagged so the internals toggle reaches it" do
    poll = polls(:maine_poll_one)
    poll.update!(partisan: :rep)

    get polls_path

    assert_select "[data-testid='poll-feed-row'][data-poll-id='#{poll.id}'][data-internal-poll]" do
      assert_select "[data-testid='sponsor-badge']", text: /rep sponsor/i
    end
  end

  test "the feed is linked from the site nav" do
    get polls_path

    assert_select "nav a[href='#{polls_path}']"
  end

  # Site::PollFeedTest owns the slicing itself; this is about the query string
  # reaching it — a controller that dropped ?page= would serve page one on
  # the second request here, rows and all.
  test "a corpus larger than one page offers a link to the older polls" do
    98.times { |n| create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 8, 1), created_at: n.minutes.ago) }
    assert_operator Poll.model_corpus.count, :>, Site::PollFeed::PER_PAGE

    get polls_path

    assert_select "[data-testid='poll-feed-row']", count: Site::PollFeed::PER_PAGE
    assert_select "[data-testid='poll-feed-older'][href='#{polls_path(page: 2)}']"
    assert_select "[data-testid='poll-feed-newer']", count: 0

    get polls_path(page: 2)

    assert_select "[data-testid='poll-feed-row']", count: Poll.model_corpus.count - Site::PollFeed::PER_PAGE
    assert_select "[data-testid='poll-feed-newer'][href='#{polls_path}']"
    assert_select "[data-testid='poll-feed-older']", count: 0
  end

  test "the note about partisan-sponsored polls links to the section that explains them" do
    get polls_path
    assert_select "[data-testid='poll-feed-note'] a[href='#{methodology_path(anchor: 'internals')}']"

    get methodology_path
    assert_select "##{'internals'}", count: 1
  end

  # A hundred rows a page, each reaching through race.candidates for its
  # margin and through result.candidate for its names — an N+1 on either is
  # a hundred queries per request.
  #
  # The added polls carry candidate-attached results on purpose. create_poll's
  # default results have no candidate, and a nil belongs_to issues no query,
  # so polls built that way cannot reveal a missing poll_results: :candidate
  # preload — the measurement stays flat whether or not the N+1 exists.
  test "the page costs the same number of queries however many polls are on it" do
    3.times { |n| create_poll_with_named_results(race: races(:senate_maine), dem: candidates(:maine_dem), rep: candidates(:maine_rep), created_at: n.minutes.ago) }
    baseline = count_queries { get polls_path }
    assert_operator baseline, :>, 0, "the measurement itself has to be reaching the database"

    3.times { |n| create_poll_with_named_results(race: races(:house_ny_17), dem: candidates(:ny17_dem), rep: candidates(:ny17_rep), created_at: (10 + n).minutes.ago) }

    assert_equal baseline, count_queries { get polls_path }
  end

  # Rack parses ?page[]=2 as an Array and ?page[x]=2 as a hash, and neither
  # responds to to_i. A hostile or merely malformed link must not be a 500.
  test "a non-scalar page parameter is treated as page one rather than raising" do
    get polls_path, params: { page: [ "2" ] }
    assert_response :success
    assert_select "[data-testid='poll-feed-row']", count: Poll.model_corpus.count

    get polls_path, params: { page: { x: "2" } }
    assert_response :success
  end

  # A page past the end is a stale bookmark, not a page. Sending the reader to
  # the last real page keeps every cache bounded by the corpus rather than by
  # whatever number was typed: a redirect is never edge-cached, and the
  # fragment key only ever sees page numbers that exist.
  test "a page past the end redirects to the last page" do
    get polls_path(page: 99)
    assert_redirected_to polls_path

    98.times { |n| create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 8, 1), created_at: n.minutes.ago) }
    assert_equal 2, (Poll.model_corpus.count.to_f / Site::PollFeed::PER_PAGE).ceil

    get polls_path(page: 99)
    assert_redirected_to polls_path(page: 2)
    assert_nil response.headers["CDN-Cache-Control"], "a redirect must not be handed to the edge cache"
  end

  # The fragment renders pollster names and candidate names, and takes each
  # margin's party letter from the race's candidates — none of which is a
  # poll row. A key that watched only polls would hold a renamed pollster,
  # or a wrong letter after a nominee was added, until the next sweep.
  test "the fragment is busted by a pollster rename and by a candidate change" do
    with_fragment_caching do
      get polls_path
      assert_select "[data-testid='poll-feed-row']", text: /Beacon Polling/
      assert_select "[data-testid='poll-feed-results']", text: /Jordan Ellis/

      pollsters(:beacon_polling).update!(name: "Beacon Renamed")
      get polls_path
      assert_select "[data-testid='poll-feed-row']", text: /Beacon Renamed/
      assert_select "[data-testid='poll-feed-row']", text: /Beacon Polling/, count: 0

      candidates(:maine_dem).update!(name: "Jordan Renamed")
      get polls_path
      assert_select "[data-testid='poll-feed-results']", text: /Jordan Renamed/
      assert_select "[data-testid='poll-feed-results']", text: /Jordan Ellis/, count: 0
    end
  end

  private
    def create_poll_with_named_results(race:, dem:, rep:, created_at:)
      poll = create_poll(pollster: pollsters(:beacon_polling), race: race, field_end: Date.new(2026, 8, 1), created_at: created_at)
      poll.poll_results.create!(party: :dem, pct: 48.0, candidate: dem)
      poll.poll_results.create!(party: :rep, pct: 45.0, candidate: rep)
      poll
    end

  test "with no polls at all the feed has an honest empty state" do
    Poll.destroy_all

    get polls_path

    assert_response :success
    assert_select "[data-testid='poll-feed-empty']", text: /No polls have been collected yet/
    assert_select "[data-testid='poll-feed-row']", count: 0
  end
end
