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
    headlines = css_select("[data-testid='dispatch-card'] h3").map(&:text)
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
end
