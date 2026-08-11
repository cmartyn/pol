# The suite runs with config.cache_store = :null_store (config/environments/
# test.rb) so every `<% cache %>` block always misses and its content always
# runs — correct for keeping the rest of the suite cache-oblivious, but it
# means real fragment reuse can only be proven by a test that opts into an
# actual store, deliberately, for its own duration. `perform_caching` and
# `cache_store` are both delegated to a controller *class's* `config`
# (AbstractController::Caching), and `ActionController::Base.cache_store`
# is only ever seeded from `Rails.cache` once, at boot
# (action_controller/railtie.rb: `options.cache_store ||= Rails.cache`) — so
# reassigning `Rails.cache` alone at runtime does not reach it. Both must be
# set directly on the controller class for a test to see a real cache hit.
module FragmentCachingHelper
  def with_fragment_caching
    previous_perform_caching = ActionController::Base.perform_caching
    previous_cache_store = ActionController::Base.cache_store
    ActionController::Base.cache_store = ActiveSupport::Cache::MemoryStore.new
    ActionController::Base.perform_caching = true
    yield
  ensure
    ActionController::Base.perform_caching = previous_perform_caching
    ActionController::Base.cache_store = previous_cache_store
  end
end
