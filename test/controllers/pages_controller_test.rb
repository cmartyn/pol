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
    # The note is whatever trails the URL — today a retrieval date. Pinning the
    # date itself would fail every time a model slug is re-verified, which is a
    # thing we want to be cheap.
    assert_select "[data-testid='param-table-newsroom'] [data-testid='param-citation']",
                  text: /\(retrieved \d{4}-\d{2}-\d{2}\)/
    assert_select "a[href*=' ']", false, "no citation link should have whitespace in its href"
  end

  test "methodology includes the site.* params this phase added" do
    get methodology_path
    assert_select "[data-testid='param-table-site'] [data-testid='param-row']", text: /tossup_band_pp/
    assert_select "[data-testid='param-table-site'] [data-testid='param-row']", text: /65/
  end

  # Phase 9's params, and the two that had to be chosen without a published
  # precedent, all render with their citations like every other number.
  test "methodology renders the house_effects params with their citations" do
    get methodology_path

    assert_select "[data-testid='param-table-house_effects'] [data-testid='param-row']", text: /shrinkage_k/
    assert_select "[data-testid='param-table-house_effects'] [data-testid='param-row']", text: /max_effect_pp/
    assert_select "[data-testid='param-table-house_effects'] [data-testid='param-row']",
                  text: /residual_half_life_days/
    assert_select "[data-testid='param-table-house_effects'] [data-testid='param-row']",
                  text: /min_comparison_pollsters/
    assert_select "[data-testid='param-table-house_effects'] a[href='https://abcnews.com/538/538s-pollster-ratings-work/story?id=105398138']"
    assert_select "[data-testid='param-table-house_effects'] a[href='https://www.natesilver.net/p/which-polls-are-biased-toward-harris']"
  end

  test "methodology explains house effects in plain language, and owns the single-pass shortcut" do
    get methodology_path

    assert_select "#house-effects"
    assert_select "[data-testid='house-effects']" do
      assert_select "*", text: /residual/
      assert_select "*", text: /firm's own polls are excluded from the comparison/
      assert_select "*", text: /pulled toward zero/
      assert_select "*", text: /capped at/
    end
    assert_select "[data-testid='single-pass-note']", text: /compute house effects once/
    assert_select "[data-testid='single-pass-note']", text: /simplification, not a refinement/
  end

  # Phase 10 closed the "single national error term" limitation and opened a
  # narrower one in its place: there are four correlated components now, at
  # 538's own values, and what is missing is their fifth.
  test "methodology's Known limitations section names the omitted error component, with the measured range" do
    get methodology_path

    assert_select "[data-testid='limitations']" do
      assert_select "li", text: /One correlated error component is missing/
      assert_select "li", text: /demographic-cluster/
      assert_select "li", text: /4\.12 against their 4\.58/
      assert_select "li", text: /93\.1%/            # the measured live figure the range was taken from
      assert_select "li", text: /0\.4 and 3\.4/     # ... and the range itself
      # The far end assumes the omitted term correlates every district at once,
      # which a clustering cannot do. Stating the range without that caveat
      # would be quoting an unreachable bound as if it were a live possibility
      # — the same error Phase 3's caveat made (BUILD_NOTES Phase 3 §A4).
      assert_select "li", text: /far end of that range assumes/
      # And no directional claim about the Senate, whose spread across the
      # three assumptions is inside Monte Carlo noise at this many sims.
      assert_select "li", text: /inside sampling noise/
      # Phase 9 closed "no pollster house-effect correction" and opened a
      # narrower one in its place: there IS a correction now, and the honest
      # caveat is that it is estimated in one pass where 538 and Silver
      # Bulletin both iterate.
      assert_select "li", text: /[Hh]ouse effects are computed in a single pass/
      assert_select "li", text: /redistricting-stale/
      assert_select "li", text: /[Ii]mputed baseline/
      assert_select "li", text: /[Uu]nsettled nominee/
    end
  end

  # M1: the imputed-baseline sentence used to hardcode "37 of 435 (8.5%)" —
  # this proves it now reads live data instead, by changing the live data and
  # checking the sentence follows.
  test "methodology's imputed-baseline count reflects the live House data, not a hardcoded figure" do
    # The fixture board already carries 1 House district (house_ny_17, not
    # imputed); adding 3 imputed ones makes 3 of 4 (75.0%) — a figure only a
    # live query, not a hardcoded string, could produce.
    3.times do |n|
      Race.create!(office: :house, state: "OH", district: 90 + n, cycle: 2026,
                   slug: "house-oh-#{90 + n}-imputed-test", baseline_margin: 35.0, baseline_imputed: true)
    end

    get methodology_path

    assert_select "[data-testid='limitations'] li", text: /3 of 4 House districts \(75\.0%\)/
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
