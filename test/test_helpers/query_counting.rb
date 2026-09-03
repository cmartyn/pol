# Counts real SQL queries — skipping cached statements and schema
# introspection, the same exclusions ActiveRecord's own assert_queries_count
# applies — for tests that want to compare a query count across two
# scenarios (e.g. "does adding more rows add more queries?") rather than
# assert a single brittle literal.
#
# The ActiveRecord query cache is cleared before every measurement, and that
# is load-bearing. Rails' transactional tests enable the query cache on the
# test's connection before the test body runs, and every request or query the
# test then makes shares that one connection — so without the clear, a second
# identical query (or a whole second request) is answered from the cache,
# arrives with payload[:cached] set, is rightly skipped here, and counts zero.
# The per-request executor hooks do not help: they only clear caches they
# themselves enabled, and this one was enabled by the fixture. Four tests in
# test/controllers/fragment_caching_test.rb were vacuous for exactly this
# reason — `second < first` held for a page with no fragment caching at all,
# because `second` was always zero — and two table tests defended against it
# by hand with "deliberately no warm-up call" comments. Clearing here makes
# the trap impossible rather than avoidable: it can only ever raise a count,
# never lower one, so no honest measurement changes.
module QueryCounting
  def count_queries
    ActiveRecord::Base.connection.clear_query_cache

    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless payload[:cached] || payload[:name] == "SCHEMA"
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
