require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "methodology renders every params section with a spot-checked value and its citation" do
    get methodology_path
    assert_response :success

    # A value straight off config/model_params.yml...
    assert_select "[data-testid='param-table-averaging'] [data-testid='param-row']", text: /window_days/ do
      assert_select "[data-testid='param-value']", text: "45"
    end
    # ...and a citation surfaced next to a different key.
    assert_select "[data-testid='param-table-fundamentals'] [data-testid='param-citation']",
                  text: /en.wikipedia.org\/wiki\/2024_United_States_House_of_Representatives_elections/
  end

  # Found by the Phase 7 acceptance sweep: newsroom.writer_model's citation is
  # a URL followed by a retrieval date, and linking the whole string put a
  # space inside the href — a source link that 404s on the page that exists to
  # make every number checkable.
  test "a citation with a trailing note links only the URL, and keeps the note as text" do
    get methodology_path

    assert_select "[data-testid='param-table-newsroom'] a[href='https://openrouter.ai/api/v1/models']"
    assert_select "[data-testid='param-table-newsroom'] [data-testid='param-citation']",
                  text: /retrieved 2026-08-11/
    assert_select "a[href*=' ']", false, "no citation link should have whitespace in its href"
  end

  test "methodology includes the site.* params this phase added" do
    get methodology_path
    assert_select "[data-testid='param-table-site'] [data-testid='param-row']", text: /tossup_band_pp/
    assert_select "[data-testid='param-table-site'] [data-testid='param-row']", text: /65/
  end

  test "methodology's Known limitations section names the House overconfidence, with the measured range" do
    get methodology_path

    assert_select "[data-testid='limitations']" do
      assert_select "li", text: /House control probability is overconfident/
      assert_select "li", text: /85.{1,3}95%/ # the measured range, en-dash or hyphen either way
      assert_select "li", text: /pollster house-effect/
      assert_select "li", text: /redistricting-stale/
      assert_select "li", text: /[Ii]mputed baseline/
      assert_select "li", text: /[Uu]nsettled nominee/
    end
  end

  test "methodology's How the forecast works section is present with an anchor" do
    get methodology_path
    assert_select "#how-it-works"
    assert_select "#known-limitations"
  end

  test "about renders the no-secret-sauce thesis, the editor model, and contact" do
    get about_path
    assert_response :success
    assert_select "body", text: /No secret sauce/
    assert_select "a[href^='mailto:']"
    assert_select "a[href='#{methodology_path}']"
  end

  test "neither page requires authentication" do
    get methodology_path
    assert_response :success
    get about_path
    assert_response :success
  end
end
