# Names vary in punctuation and spacing across publishers. Prefer a verified
# FIPS join, then an unambiguous normalized name within the same state. Never
# merge a city into its surrounding county merely because both report votes.
class ElectionNight::CountyIdentity
  def initialize(units)
    @by_fips, @by_name = {}, {}
    units.each do |unit|
      state, fips, key = unit.values_at("state", "county_fips", "unit_key")
      next unless state && key
      name = [ state, token(key) ]
      @by_name[name] ||= []
      # A punctuation-only legacy alias must not make a verified name ambiguous.
      canonical = if fips
        @by_fips[[ state, fips ]] ||= key
      elsif @by_name[name].size == 1
        @by_name[name].first
      else
        key
      end
      @by_name[name] |= [ canonical ]
    end
  end

  def normalize(state, unit)
    key = if unit["county_fips"]
      @by_fips[[ state, unit["county_fips"] ]]
    else
      matches = @by_name[[ state, token(unit.fetch("unit_key")) ]]
      matches&.size == 1 ? matches.first : nil
    end
    unit.merge("unit_key" => key || unit.fetch("unit_key"), "historical_county_match" => !key.nil?)
  end

  private
    def token(value)
      # ZIP/CSV adapters can retain ASCII-8BIT even for valid UTF-8 text. Do
      # not discard accents or invalid bytes before checking their encoding.
      text = value.dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "invalid UTF-8 county name" unless text.valid_encoding?
      text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").upcase.gsub(/[^\p{Alnum}]/, "")
    end
end
