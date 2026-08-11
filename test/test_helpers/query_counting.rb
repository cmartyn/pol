# Counts real SQL queries — skipping cached statements and schema
# introspection, the same exclusions ActiveRecord's own assert_queries_count
# applies — for tests that want to compare a query count across two
# scenarios (e.g. "does adding more rows add more queries?") rather than
# assert a single brittle literal.
module QueryCounting
  def count_queries
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
