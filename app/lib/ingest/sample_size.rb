module Ingest
  # Parses the "Sample size" cell of a Wikipedia polling table.
  #
  #   Ingest::SampleSize.parse("1,048 (LV)")  # => [1048, :lv]
  #   Ingest::SampleSize.parse("–")           # => [nil, :unknown]
  #
  # The population codes that actually appear are LV, RV, A and V. "V"
  # (voters) is not one of the three populations the schema defines, so it maps
  # to :unknown rather than being quietly rounded to registered voters — v1
  # applies no population adjustment anyway.
  module SampleSize
    POPULATIONS = { "lv" => :lv, "rv" => :rv, "a" => :a }.freeze
    PATTERN = /\A([\d,]+)\s*(?:\(\s*([A-Za-z]+)\s*\))?/

    # Returns [size_or_nil, population_symbol].
    def self.parse(text)
      value = text.to_s.tr(" ", " ").gsub(/\s+/, " ").strip
      match = PATTERN.match(value)
      return [ nil, :unknown ] if match.nil?

      size = match[1].delete(",").to_i
      [ size.positive? ? size : nil, POPULATIONS.fetch(match[2].to_s.downcase, :unknown) ]
    end
  end
end
