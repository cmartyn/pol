require "test_helper"

class PollstersControllerTest < ActionDispatch::IntegrationTest
  def effect_for(pollster, run: model_runs(:model_run_one), **attributes)
    HouseEffect.create!({
      model_run: run, pollster: pollster,
      effect_raw: 2.0, effect_shrunk: 1.0, residual_count: 8, applied: true
    }.merge(attributes))
  end

  test "the page lists every pollster with at least one poll" do
    get pollsters_path
    assert_response :success

    assert_select "[data-testid='pollster-row']", count: Poll.distinct.count(:pollster_id)
    assert_select "[data-testid='pollsters-table']", text: /Beacon Polling/
    assert_select "[data-testid='pollsters-table']", text: /Cardinal Research/
  end

  # The sign convention is the one thing on this page a reader cannot work
  # out for themselves, and getting it backwards would invert every number.
  test "the sign convention is stated in words, at the top, with the direction of the adjustment" do
    get pollsters_path

    assert_select "[data-testid='sign-convention']" do
      assert_select "*", text: /D\+0\.8 means this pollster's polls run 0\.8 points more Democratic than the field/
      assert_select "*", text: /we subtract that before averaging/
    end
  end

  test "an estimated effect renders raw, shrunk, its residual count and its applied status" do
    effect_for(pollsters(:beacon_polling), effect_raw: 4.0, effect_shrunk: 2.5, residual_count: 12)

    get pollsters_path

    assert_select "[data-testid='pollster-row'][data-applied='true']" do
      assert_select "[data-testid='raw-effect']", text: /D\+4\.0/
      assert_select "[data-testid='shrunk-effect']", text: /D\+2\.5/
      assert_select "[data-testid='residual-count']", text: "12"
      assert_select "[data-testid='pollster-status']", text: /Applied/
    end
  end

  test "a Republican-leaning effect renders on the R side of the same convention" do
    effect_for(pollsters(:beacon_polling), effect_raw: -4.0, effect_shrunk: -2.5)

    get pollsters_path

    assert_select "[data-testid='shrunk-effect']", text: /R\+2\.5/
  end

  # Shown, but visibly not acted on — the whole point of publishing the ones
  # the model declined to use.
  test "an effect under the minimum is displayed and marked as not applied" do
    effect_for(pollsters(:beacon_polling), effect_raw: 6.0, effect_shrunk: 1.2,
               residual_count: 1, applied: false)

    get pollsters_path

    assert_select "[data-testid='pollster-row'][data-applied='false']" do
      assert_select "[data-testid='shrunk-effect']", text: /D\+1\.2/
      assert_select "[data-testid='pollster-status']", text: /Shown only/
    end
  end

  # "No estimate" and "an estimate of zero" are different claims.
  test "a pollster the estimator could not reach shows no estimate rather than a zero" do
    get pollsters_path

    assert_select "[data-testid='pollster-row'][data-applied='false']" do
      assert_select "[data-testid='pollster-status']", text: /No estimate/
      assert_select "[data-testid='shrunk-effect']", text: /—/
    end
  end

  test "rows are ordered by the size of the effect, largest first" do
    effect_for(pollsters(:beacon_polling), effect_shrunk: 0.4)
    effect_for(pollsters(:cardinal_research), effect_shrunk: -2.9)
    effect_for(pollsters(:delta_metrics), effect_shrunk: 1.1)

    get pollsters_path

    names = css_select("[data-testid='pollster-row'] td:first-child").map { |cell| cell.text.strip }
    assert_equal [ "Cardinal Research", "Delta Metrics", "Beacon Polling" ], names
  end

  test "the summary counts how many are estimated and how many applied" do
    effect_for(pollsters(:beacon_polling))
    effect_for(pollsters(:cardinal_research), applied: false, residual_count: 2)

    get pollsters_path

    assert_select "[data-testid='pollster-summary']", text: /3 pollsters/
    assert_select "[data-testid='pollster-summary']", text: /2 with an estimated effect/
    assert_select "[data-testid='pollster-summary']", text: /1 whose effect is being applied/
  end

  test "before any run has estimated effects the page says so instead of implying zeroes" do
    get pollsters_path

    assert_select "[data-testid='no-effects-yet']", text: /No forecast run has estimated house effects yet/
    assert_select "[data-testid='pollster-row']", count: Poll.distinct.count(:pollster_id)
  end

  test "with no polls at all the page has an honest empty state" do
    Poll.destroy_all

    get pollsters_path

    assert_response :success
    assert_select "[data-testid='pollsters-empty']", text: /No polls have been collected yet/
    assert_select "[data-testid='pollster-row']", count: 0
  end

  test "the page is linked from the site nav and from the methodology page" do
    get pollsters_path
    assert_select "nav a[href='#{pollsters_path}']"

    get methodology_path
    assert_select "a[href='#{pollsters_path}']"
  end

  # The page lists every pollster in the corpus, so an N+1 here is one query
  # per firm — 154 of them on the live board.
  test "the table is built in a bounded number of queries however many pollsters there are" do
    run = model_runs(:model_run_one) # loaded here so the fixture read is not inside a measurement
    6.times { |n| create_poll(pollster: create_pollster("Extra Polling #{n}"), field_end: Date.new(2026, 7, 1)) }

    baseline = count_queries { Site::PollsterTable.build(model_run: run) }

    6.times { |n| create_poll(pollster: create_pollster("More Polling #{n}"), field_end: Date.new(2026, 7, 1)) }

    assert_equal baseline, count_queries { Site::PollsterTable.build(model_run: run) }
    assert_equal 3, baseline, "poll counts, the run's effects, and the pollsters themselves"
  end
end
