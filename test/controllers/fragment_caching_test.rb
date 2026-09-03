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
# block specifically so a hit skips it; counting queries across two requests
# is what makes that provable rather than assumed.
#
# Two kinds of test here, and they are falsified by different mutations. The
# four reuse tests (assert_fragment_reused) fail when perform_caching is
# flipped off in FragmentCachingHelper — verified. The five busting tests
# below them cannot fail that way: they assert content *changes* after a
# write, which a disabled cache trivially satisfies. They fail instead when
# the thing they guard is broken — a key that drops @latest_run/@sort or
# @latest_dispatch, `touch: true` removed from Candidate, the explicit race
# touch removed from Admin::DispatchesController — each verified by mutation.
#
# The reuse tests were vacuous until count_queries learned to clear the AR
# query cache (see test/test_helpers/query_counting.rb): the second GET was
# answered from that cache, counted zero, and `second < first` held for a
# page with no fragment caching at all.
class FragmentCachingTest < ActionDispatch::IntegrationTest
  test "the Senate table skips Site::SenateTable.build's queries on a cache hit" do
    assert_fragment_reused senate_path
  end

  test "the House table skips Site::HouseTable.build's queries on a cache hit" do
    assert_fragment_reused house_path
  end

  test "a race page's core content is not rebuilt on a cache hit" do
    assert_fragment_reused race_path(races(:senate_maine).slug)
  end

  test "dashboard chamber cards are not rebuilt on a cache hit" do
    assert_fragment_reused root_path
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

  # F4a: Candidate belongs_to :race, touch: true — an admin candidate edit (or
  # the post-primary pol:seed_races re-run) must bust the race page's cache
  # entry, since the candidate list rendered there is built inside the
  # `<% cache %>` block keyed on [race, latest_run, latest_dispatch].
  test "a candidate change busts a race page's cache entry" do
    with_fragment_caching do
      get race_path(races(:senate_maine).slug)
      assert_select "li", text: /Sam Winter/

      candidates(:maine_ind).update!(name: "Alex Renamed")

      get race_path(races(:senate_maine).slug)
      assert_select "li", text: /Sam Winter/, count: 0
      assert_select "li", text: /Alex Renamed/
    end
  end

  # F4b: retracting (or editing) a dispatch that is NOT the race's current
  # latest published one does not change @latest_dispatch, so without
  # Admin::DispatchesController touching the race explicitly, the cache key
  # would stay identical and the retracted piece would keep rendering in the
  # cached feed until something else happened to bust it.
  test "retracting an older, non-latest dispatch busts a race page's cache entry" do
    with_fragment_caching do
      older = dispatches(:maine_poll_reaction)
      Dispatch.create!(
        race: races(:senate_maine), kind: :movement_note, headline: "A newer dispatch lands",
        body_markdown: "More words about the Maine Senate race.", model_slug: "fixture/writer-model",
        status: :published, published_at: older.published_at + 1.day
      )

      get race_path(races(:senate_maine).slug)
      assert_select "[data-testid='dispatch-card']", count: 2

      sign_in_as users(:one)
      post retract_admin_dispatch_path(older)

      get race_path(races(:senate_maine).slug)
      assert_select "[data-testid='dispatch-card']", count: 1
    end
  end

  private
    # Fetch `path` twice with a real fragment store in place and prove the
    # second render did less database work than the first — i.e. that the
    # page's `<% cache %>` block actually held, and that the queries it wraps
    # are inside it rather than in the controller.
    def assert_fragment_reused(path)
      with_fragment_caching do
        first = count_queries { get path }
        second = count_queries { get path }

        assert_response :success
        assert_operator first, :>, 0,
          "#{path} made no queries at all, so this proves nothing about caching"
        assert_operator second, :<, first,
          "#{path} cost #{second} queries on a warm cache and #{first} on a cold one — " \
          "its expensive queries are not inside the cache block"
      end
    end
end
