module Admin
  # A flat dot-notation diff between two params_snapshot jsonb hashes — the
  # model run show page's "what changed since the last succeeded run" panel.
  # Deliberately simple: no array-element diffing, no type coercion beyond
  # what the two hashes already carry — a snapshot is config (config/
  # model_params.yml, read once per run), not data, so a key added,
  # removed, or whose value changed is the whole vocabulary this needs.
  module ParamsDiff
    module_function

    Change = Struct.new(:key, :before, :after, keyword_init: true)

    # ParamsDiff.call(current: run.params_snapshot, previous: previous_run&.params_snapshot)
    # => { added: [Change...], removed: [Change...], changed: [Change...] }
    # Either snapshot may be nil (an old or failed run may have none) — nil
    # is treated the same as an empty snapshot rather than raising.
    def call(current:, previous:)
      current_flat = flatten(current || {})
      previous_flat = flatten(previous || {})

      {
        added: (current_flat.keys - previous_flat.keys).sort.map { |key| Change.new(key: key, before: nil, after: current_flat[key]) },
        removed: (previous_flat.keys - current_flat.keys).sort.map { |key| Change.new(key: key, before: previous_flat[key], after: nil) },
        changed: (current_flat.keys & previous_flat.keys).select { |key| current_flat[key] != previous_flat[key] }
                   .sort.map { |key| Change.new(key: key, before: previous_flat[key], after: current_flat[key]) }
      }
    end

    # flatten({"a" => 1, "b" => {"c" => 2}}) => {"a" => 1, "b.c" => 2}
    def flatten(hash, prefix = nil)
      hash.each_with_object({}) do |(key, value), result|
        full_key = prefix ? "#{prefix}.#{key}" : key.to_s
        if value.is_a?(Hash)
          result.merge!(flatten(value, full_key))
        else
          result[full_key] = value
        end
      end
    end
  end
end
