require "test_helper"

class Site::CacheKeyTest < ActiveSupport::TestCase
  test "collection_freshness pairs the newest updated_at with the row count" do
    scope = Race.where(slug: [ races(:senate_maine).slug, races(:senate_florida_special).slug ])
    newest = [ races(:senate_maine), races(:senate_florida_special) ].max_by(&:updated_at)

    max, count = Site::CacheKey.collection_freshness(scope)

    assert_equal newest.updated_at.to_fs(:usec), max
    assert_equal 2, count
  end

  # Rails expands a Time in a cache key through #to_a — seconds, minutes,
  # hours and so on, no fraction — so left to itself every write inside one
  # wall-clock second keys identically, and a rename a moment after the
  # previous render is served from that render's fragment. The first pair
  # documents that; the second is the helper that exists because of it.
  test "two times in the same second are one key to Rails, and two to timestamp" do
    at = Time.zone.local(2026, 9, 14, 12, 0, 0)
    later = at + 0.5

    assert_equal ActiveSupport::Cache.expand_cache_key(at), ActiveSupport::Cache.expand_cache_key(later)
    refute_equal ActiveSupport::Cache.expand_cache_key(Site::CacheKey.timestamp(at)),
                 ActiveSupport::Cache.expand_cache_key(Site::CacheKey.timestamp(later))
  end

  test "timestamp of nothing is nothing" do
    assert_nil Site::CacheKey.timestamp(nil)
  end

  test "a touch in the same second as the last one still changes the key" do
    scope = Race.where(id: races(:senate_maine).id)
    second = 1.day.from_now.change(usec: 0)

    travel_to(second) { races(:senate_maine).touch }
    before = ActiveSupport::Cache.expand_cache_key(Site::CacheKey.collection_freshness(scope))

    travel_to(second + 0.5, with_usec: true) { races(:senate_maine).touch }
    after = ActiveSupport::Cache.expand_cache_key(Site::CacheKey.collection_freshness(scope))

    refute_equal before, after
  end

  test "touching a record in the collection changes the key" do
    scope = Race.where(id: races(:senate_maine).id)
    before = Site::CacheKey.collection_freshness(scope)

    travel_to(1.hour.from_now) { races(:senate_maine).touch }

    after = Site::CacheKey.collection_freshness(scope)

    refute_equal before, after
  end

  test "adding a record to the collection changes the key" do
    before = Site::CacheKey.collection_freshness(Race.senate)

    Race.create!(office: :senate, state: "ZZ", cycle: 2026, slug: "cache-key-test-extra-senate-race")

    after = Site::CacheKey.collection_freshness(Race.senate)

    refute_equal before, after
  end

  test "an empty collection is a stable, non-crashing key" do
    max, count = Site::CacheKey.collection_freshness(Race.where(office: :governor))

    assert_nil max
    assert_equal 0, count
  end
end
