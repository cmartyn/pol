module Pol
  # Loads config/model_params.yml — the single source of truth for every
  # forecast/newsroom constant — once per process and exposes it as a
  # deeply-symbolized hash. The public methodology page renders straight
  # from #to_h, so if a parameter isn't in that file, it doesn't exist.
  module Params
    CONFIG_PATH = Rails.root.join("config", "model_params.yml")

    class << self
      # Pol::Params.fetch!(:averaging, :half_life_days) => 14
      #
      # Walks the given path of keys and returns the value at the end.
      # Raises KeyError, with the full path in the message, if any key
      # along the way is missing. Also raises KeyError if the resolved
      # value is nil, unless allow_nil: true is passed — some parameters
      # (e.g. newsroom model slugs) are legitimately null until a later
      # phase fills them in.
      def fetch!(*keys, allow_nil: false)
        value = keys.reduce(to_h) do |hash, key|
          unless hash.is_a?(Hash) && hash.key?(key)
            raise KeyError, "Pol::Params: no value at #{keys.inspect} (missing key #{key.inspect}, from #{CONFIG_PATH})"
          end

          hash[key]
        end

        if value.nil? && !allow_nil
          raise KeyError, "Pol::Params: value at #{keys.inspect} is nil (pass allow_nil: true if that's expected)"
        end

        value
      end

      # The full params tree, deeply symbolized. Memoized per process.
      def to_h
        @to_h ||= YAML.safe_load_file(CONFIG_PATH).deep_symbolize_keys
      end

      # Clears the memoized params so the next call re-reads the YAML file
      # from disk. Intended for tests.
      def reload!
        @to_h = nil
        to_h
      end
    end
  end
end
