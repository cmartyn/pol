require "test_helper"

class DispatchesControllerTest < ActionDispatch::IntegrationTest
  test "index renders every published dispatch, newest first" do
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
    assert_select "[data-testid='dispatch-dek']", text: dispatch.dek
    # The feed truncates; the permalink is the place the whole piece exists.
    assert_select "[data-testid='dispatch-body']", text: /Cardinal Research found a tighter/
    assert_select "[data-testid='dispatch-byline']", text: /#{Regexp.escape(dispatch.model_slug)}/
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
end
