# Minitest 6 no longer ships Object#stub, and the suite needs a couple of
# targeted ones — forcing a "not there" read so the database's unique index
# gets its turn at catching a duplicate, and watching a seam get called.
module StubHelper
  # stubbing(Poll, :exists?, false) { ... }
  def stubbing(object, name, value, &block)
    replacing(object, name, ->(*, **) { value }, &block)
  end

  # recording(Ingest, :after_new_polls!) { |calls| ...; assert_equal [ [ 4 ] ], calls }
  def recording(object, name)
    calls = []
    replacing(object, name, ->(*args, **) { calls << args }) { yield calls }
  end

  # raising(ChamberForecast, :insert_all!, "database is on fire") { ... }
  def raising(object, name, message, &block)
    replacing(object, name, ->(*, **) { raise message }, &block)
  end

  # with_params(chambers: { vp_party: "dem" }) { ... }
  #
  # Overrides model_params.yml for the duration of the block, so a test can
  # prove a constant is genuinely read from the file rather than hardcoded
  # somewhere that happens to agree with it. Pol::Params memoises per process
  # and reload! re-reads from disk, so the restore is exact.
  def with_params(overrides)
    Pol::Params.to_h.deep_merge!(overrides)
    yield
  ensure
    Pol::Params.reload!
  end

  private
    def replacing(object, name, implementation)
      singleton = object.singleton_class
      owned = singleton.instance_methods(false).include?(name)
      singleton.alias_method(:__stub_original, name) if owned
      singleton.define_method(name, &implementation)

      yield
    ensure
      singleton.remove_method(name)
      if owned
        singleton.alias_method(name, :__stub_original)
        singleton.remove_method(:__stub_original)
      end
    end
end
