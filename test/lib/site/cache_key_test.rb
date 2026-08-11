require "test_helper"

class Site::CacheKeyTest < ActiveSupport::TestCase
  test "collection_freshness pairs the newest updated_at with the row count" do
    scope = Race.where(slug: [ races(:senate_maine).slug, races(:senate_florida_special).slug ])
    newest = [ races(:senate_maine), races(:senate_florida_special) ].max_by(&:updated_at)

    max, count = Site::CacheKey.collection_freshness(scope)

    assert_equal newest.updated_at, max
    assert_equal 2, count
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
