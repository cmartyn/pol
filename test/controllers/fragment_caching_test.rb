require "test_helper"

# Phase 4 fix round, Finding 1: the dashboard's chamber cards, the Senate
# table, the House table and a race page's core content are each wrapped in
# a `<% cache %>` block (app/views/home/_chamber_card.html.erb,
# app/views/races/{senate,house,show}.html.erb) keyed on whichever of
# [latest succeeded model run, latest dispatch, race updated_at] the brief's
# Performance section says is relevant to what that fragment shows. The rest
# of the suite runs against config.cache_store :null_store (config/
# environments/test.rb), so every other test exercises each block's content
# on every request — correct for keeping those tests cache-oblivious, but it
# means fragment reuse itself can only be proven here, with a real store
# opted into for the duration of each test (see FragmentCachingHelper).
#
# Each surface's expensive part — Site::SenateTable.build, Site::HouseTable
# .build, the ChamberForecast lookup + histogram build, and the race page's
# forecast/timeline/polls/dispatches queries — lives *inside* its cache
# block specifically so a hit skips it; count_queries (test/test_helpers/
# query_counting.rb) is what makes that provable rather than assumed.
class FragmentCachingTest < ActionDispatch::IntegrationTest
  test "the Senate table skips Site::SenateTable.build's queries on a cache hit" do
    with_fragment_caching do
      first = count_queries { get senate_path }
      second = count_queries { get senate_path }

      assert_operator second, :<, first
    end
  end

  test "the House table skips Site::HouseTable.build's queries on a cache hit" do
    with_fragment_caching do
      first = count_queries { get house_path }
      second = count_queries { get house_path }

      assert_operator second, :<, first
    end
  end

  test "a race page's core content is not rebuilt on a cache hit" do
    with_fragment_caching do
      first = count_queries { get race_path(races(:senate_maine).slug) }
      second = count_queries { get race_path(races(:senate_maine).slug) }

      assert_operator second, :<, first
    end
  end

  test "dashboard chamber cards are not rebuilt on a cache hit" do
    with_fragment_caching do
      first = count_queries { get root_path }
      second = count_queries { get root_path }

      assert_operator second, :<, first
    end
  end

  test "a differently-sorted Senate table is never served from the wrong sort's cache entry" do
    with_fragment_caching do
      get senate_path, params: { sort: "state", dir: "asc" }
      ascending = css_select("[data-testid='senate-race-row']").map { |row| row.css("a").first.text.strip }

      get senate_path, params: { sort: "state", dir: "desc" }
      descending = css_select("[data-testid='senate-race-row']").map { |row| row.css("a").first.text.strip }

      assert_equal ascending, descending.reverse
    end
  end

  test "a new succeeded model run busts the Senate table's cache entry" do
    with_fragment_caching do
      get senate_path
      assert_select "[data-testid='probability-chip']", text: "D 62%"

      new_run = ModelRun.create!(status: :succeeded, trigger: :cron, started_at: model_runs(:model_run_one).started_at + 1.day)
      Forecast.create!(model_run: new_run, race: races(:senate_maine), p_dem_win: 0.10, p_rep_win: 0.90, mean_margin: -15.0)

      get senate_path
      assert_select "[data-testid='probability-chip']", text: "D 62%", count: 0
      assert_select "[data-testid='probability-chip']", text: "R 90%"
    end
  end

  test "a new dispatch busts a race page's cache entry" do
    with_fragment_caching do
      get race_path(races(:senate_maine).slug)
      assert_select "[data-testid='dispatch-card']", count: 1

      Dispatch.create!(
        race: races(:senate_maine), kind: :movement_note, headline: "A second dispatch lands",
        body_markdown: "More words about the Maine Senate race.", model_slug: "fixture/writer-model",
        status: :published, published_at: Time.current
      )

      get race_path(races(:senate_maine).slug)
      assert_select "[data-testid='dispatch-card']", count: 2
    end
  end
end
