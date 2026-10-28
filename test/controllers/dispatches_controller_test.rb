require "test_helper"

class DispatchesControllerTest < ActionDispatch::IntegrationTest
  test "index renders published dispatches, newest first" do
    newer = Dispatch.create!(
      headline: "Newer dispatch", body_markdown: "Body.", kind: :daily_brief, status: :published,
      published_at: dispatches(:maine_poll_reaction).published_at + 1.day, model_slug: "fixture/writer-model"
    )

    get dispatches_path

    assert_response :success
    assert_select "[data-testid='dispatch-card']", count: Dispatch.published.count
    headlines = css_select("[data-testid='dispatch-card'] h3").map { |node| node.text.strip }
    assert_equal newer.headline, headlines.first
  end

  test "index paginates published dispatches in stable batches of thirty without side effects" do
    Dispatch.delete_all
    rows = 61.times.map do |i|
      { headline: "Dispatch #{i}", body_markdown: "Body.", kind: :daily_brief,
        status: :published, published_at: Time.utc(2026, 8, 3) }
    end
    Dispatch.insert_all!(rows + [ rows.first.merge(headline: "Retracted", status: :retracted) ])
    expected = rows.reverse.map { |row| row.fetch(:headline) }

    assert_no_changes -> { Dispatch.order(:id).pluck(:id, :status, :updated_at) } do
      assert_no_enqueued_jobs do
        (1..3).each do |page|
          get dispatches_path, params: { page: page }
          assert_response :success
          headlines = css_select("[data-testid='dispatch-card'] h3").map { |node| node.text.strip }
          assert_equal expected.slice((page - 1) * 30, 30), headlines
          assert_select "nav[aria-label='Dispatch pagination']", text: /Page #{page} of 3/
          assert_select "a[rel='prev']", count: page > 1 ? 1 : 0
          assert_select "a[rel='next']", count: page < 3 ? 1 : 0
        end

        get dispatches_path, params: { page: "9" * 100 }
        assert_response :success
        assert_select "[data-testid='dispatch-card'] h3", text: expected.last, count: 1
        assert_select "[data-testid='dispatch-card']", count: 1
        assert_select "a[rel='next']", count: 0
      end
    end
  end

  test "index normalizes invalid pages and hides pagination for a single page" do
    [ nil, "0", "-1", "nonsense", "2junk", "1.5", [ "2" ], { number: "2" } ].each do |page|
      get dispatches_path, params: { page: page }
      assert_response :success
      assert_select "[data-testid='dispatch-card']", count: Dispatch.published.count
      assert_select "nav[aria-label='Dispatch pagination']", count: 0
    end
  end

  # The layout's default canonical drops the query string, which would tell
  # search engines that page 2 is a copy of page 1 — and the older pages are
  # the only crawl path to older dispatch permalinks.
  test "each page names itself as canonical and gets its own title" do
    Dispatch.delete_all
    Dispatch.insert_all!(31.times.map do |i|
      { headline: "Dispatch #{i}", body_markdown: "Body.", kind: :daily_brief,
        status: :published, published_at: Time.utc(2026, 8, 3) }
    end)

    get dispatches_path
    assert_select "link[rel='canonical'][href$='/dispatches']"
    assert_select "title", "Dispatches · 535"

    get dispatches_path, params: { page: 2 }
    assert_select "link[rel='canonical'][href$='/dispatches?page=2']"
    assert_select "title", "Dispatches · Page 2 · 535"

    # An out-of-range page renders the last page, so it names that page.
    get dispatches_path, params: { page: 99 }
    assert_select "link[rel='canonical'][href$='/dispatches?page=2']"
  end

  test "index excludes retracted dispatches" do
    retracted = Dispatch.create!(
      headline: "Retracted dispatch", body_markdown: "Body.", kind: :daily_brief, status: :retracted,
      published_at: Time.current, model_slug: "fixture/writer-model"
    )

    get dispatches_path

    assert_select "[data-testid='dispatch-card']", text: /#{Regexp.escape(retracted.headline)}/, count: 0
  end

  test "index shows an honest empty state with none published" do
    Dispatch.delete_all
    get dispatches_path
    assert_response :success
    assert_select "[data-testid='dispatches-empty']"
    assert_select "nav[aria-label='Dispatch pagination']", count: 0
  end

  test "does not require authentication" do
    get dispatches_path
    assert_response :success
  end

  # --- the permalink ---------------------------------------------------------

  # The feed used to render every headline as plain text with nowhere to go,
  # so the way into a piece was to scroll it. The headline itself is the link
  # people reach for first.
  test "a feed headline links to its own dispatch" do
    dispatch = dispatches(:maine_poll_reaction)

    get dispatches_path

    assert_select "[data-testid='dispatch-headline-link'][href=?]", dispatch_path(dispatch),
                  text: dispatch.headline
  end

  test "show renders the headline, the full body and the byline" do
    dispatch = dispatches(:maine_poll_reaction)

    get dispatch_path(dispatch)

    assert_response :success
    assert_select "[data-testid='dispatch-headline']", text: dispatch.headline
    assert_select "[data-analytics-event-name-value='dispatch_viewed']"
    assert_select "[data-testid='dispatch-dek']", text: dispatch.dek
    # The feed truncates; the permalink is the place the whole piece exists.
    assert_select "[data-testid='dispatch-body']", text: /Cardinal Research found a tighter/
    assert_select "[data-testid='dispatch-byline']", text: /Written by the newsroom · #{Regexp.escape(dispatch.model_slug)}/
  end

  # "Every number traceable back to where it came from" is the About page's
  # claim; on a dispatch this is what keeps it.
  test "show names the polls the dispatch was written from" do
    get dispatch_path(dispatches(:maine_poll_reaction))

    assert_select "[data-testid='dispatch-cited-poll']", count: 2
    assert_select "[data-testid='dispatch-sources']", text: /Beacon Polling/
  end

  # The admin retract button promises the public site will stop showing it.
  test "show 404s for a retracted dispatch" do
    retracted = Dispatch.create!(
      headline: "Retracted dispatch", body_markdown: "Body.", kind: :daily_brief, status: :retracted,
      published_at: Time.current, model_slug: "fixture/writer-model"
    )

    get dispatch_path(retracted)

    assert_response :not_found
  end

  # to_param appends a readable slug, but the id is what resolves — so a link
  # shared before a headline was edited keeps working instead of 404ing.
  test "the permalink reads as a headline but resolves by id" do
    dispatch = dispatches(:maine_poll_reaction)

    assert_equal "#{dispatch.id}-new-maine-poll-shows-tightening-senate-race", dispatch.to_param

    get "/dispatches/#{dispatch.id}"
    assert_response :success

    get "/dispatches/#{dispatch.id}-a-completely-different-headline"
    assert_response :success
  end

  test "show does not require authentication" do
    get dispatch_path(dispatches(:maine_poll_reaction))
    assert_response :success
  end

  test "an old redrawn-district article gets a correction only after corrected forecasts publish" do
    race = Race.create!(office: :house, cycle: 2026, state: "TN", district: 9, slug: "house-2026-tn-09")
    dispatch = dispatches(:maine_poll_reaction)
    dispatch.update!(race: race)
    original = dispatch.body_markdown
    get dispatch_path(dispatch)
    assert_select "[data-testid='dispatch-baseline-correction']", count: 0

    ModelRun.create!(status: :succeeded, trigger: :manual, started_at: Time.current,
      params_snapshot: { house_baselines: { revision: Forecast::HouseBaselines.current.revision } })
    get dispatch_path(dispatch)
    assert_select "[data-testid='dispatch-baseline-correction']", text: /earlier district lines/
    assert_equal original, dispatch.reload.body_markdown
  end
end
