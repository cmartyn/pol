require "time"

# Select one coherent raw vote total per race. Aggregate totals and county
# portions represent the same ballots and must never be added together.
# These display choices do not establish eligibility for model conditioning.
class ElectionNight::RawResults
  attr_reader :county_units, :state_manifests

  def self.canonical_race_key(key)
    key.sub(/\A(AK|DE|ND|SD|VT|WY)-(?:00|01|AL)\z/, '\1-AL')
  end

  def initialize(sources:)
    # Retained snapshots remain available, but cannot shadow a healthy feed
    # merely because their registry entry comes first.
    @sources = sources.select { |source| source["usable"] }.partition { |source| !stale_source?(source) }.flatten(1)
    @county_units, @state_manifests, @by_source = {}, {}, []
    @sources.each do |source|
      counties, aggregates = {}, {}
      Array(source.dig("results", "units")).each do |unit|
        next unless valid_counts?(unit)
        unit = unit.merge("race_key" => self.class.canonical_race_key(unit.fetch("race_key")))
        identity = [ unit.fetch("race_key"), unit.fetch("unit_key") ]
        if aggregate?(unit) || source["aggregate_only"]
          aggregates[unit.fetch("race_key")] ||= unit.merge("source_id" => source.fetch("id"))
        elsif county?(unit)
          counties[identity] ||= unit.merge("source_id" => source.fetch("id"))
        end
      end
      Array(source.dig("results", "aggregate_units")).each do |unit|
        next unless valid_counts?(unit)
        unit = unit.merge("race_key" => self.class.canonical_race_key(unit.fetch("race_key")))
        aggregates[unit.fetch("race_key")] ||= unit.merge("source_id" => source.fetch("id"), "aggregate_only" => true)
      end
      counties.each { |identity, unit| @county_units[identity] ||= unit }
      manifest = counties.values.map { |unit| unit.fetch("unit_key") }.uniq.sort
      statewide = source["expected_counties"].to_i.positive? && manifest.size == source["expected_counties"].to_i
      @state_manifests[source.fetch("state")] ||= manifest if statewide
      @by_source << { source: source, counties: counties.values.group_by { |unit| unit.fetch("race_key") },
        aggregates: aggregates, statewide: statewide, manifest: manifest }
    end
  end

  def for_race(race, historical_counties: [])
    key = self.class.canonical_race_key(race.fetch("race_key"))
    # Healthy whole-race sources precede retained stale whole-race sources.
    # Within each group prefer county detail, then aggregates, in registry order.
    @by_source.partition { |entry| !stale_source?(entry[:source]) }.each do |entries|
      complete = entries.find { |entry| complete_county?(entry, key, race, historical_counties) }
      return summarize(complete[:counties].fetch(key), "county") if complete
      if (entry = entries.find { |candidate| candidate[:aggregates].key?(key) })
        return summarize([ entry[:aggregates].fetch(key) ], "contest")
      end
    end
    rows = @county_units.values.select { |row| row["race_key"] == key }
    summarize(rows, rows.any? ? "partial" : "none")
  end

  private
    def stale_source?(source)
      %w[error stale].include?(source["status"])
    end

    def complete_county?(entry, key, race, historical_counties)
      rows = entry[:counties][key]
      return false unless rows && rows.any?
      aggregate = entry[:aggregates][key]
      reconciled = entry[:source].dig("results", "county_totals_match_aggregate") == true && aggregate &&
        %w[dem_votes rep_votes other_votes total_votes].all? { |field| rows.sum { |row| row.fetch(field) } == aggregate.fetch(field) }
      # Any subset of zero rows sums to zero. Without independent geography,
      # that proves only the aggregate, not a complete county breakdown.
      return true if reconciled && aggregate.fetch("total_votes").positive?
      return false unless entry[:statewide] && entry[:source]["state"] == race["state"]
      keys = rows.map { |row| row.fetch("unit_key") }.uniq.sort
      if race["chamber"] == "senate"
        keys == entry[:manifest]
      elsif historical_counties.any?
        keys == historical_counties.sort
      else
        # A validated complete statewide source reports its House portions.
        # This labels raw source scope only; unchanged-boundary manifests are
        # still mandatory in Observations before any House update.
        true
      end
    end

    def aggregate?(unit)
      unit["aggregate_only"] == true || %w[contest statewide district].include?(unit["geography_level"])
    end

    def county?(unit)
      # Older county adapters omit geography_level. Unknown explicit levels,
      # e.g. precincts, must not silently become counties.
      unit["geography_level"].nil? || unit["geography_level"] == "county"
    end

    def valid_counts?(unit)
      fields = %w[dem_votes rep_votes other_votes total_votes]
      unit.is_a?(Hash) && unit["race_key"].is_a?(String) && unit["unit_key"].is_a?(String) &&
        fields.all? { |field| unit[field].is_a?(Integer) && unit[field] >= 0 } &&
        unit["dem_votes"] + unit["rep_votes"] + unit["other_votes"] == unit["total_votes"]
    end

    def summarize(rows, level)
      ids = rows.map { |row| row.fetch("source_id") }.uniq
      selected = @sources.select { |source| ids.include?(source["id"]) }
      sources_by_id = selected.to_h { |source| [ source.fetch("id"), source ] }
      # National exports may give every race its own update time. Their newest
      # race timestamp must not make an unchanged race appear freshly counted.
      published = rows.map do |row|
        source = sources_by_id.fetch(row.fetch("source_id"))
        row["published_at"] || source["published_at"] || source.dig("results", "published_at")
      end
      # When combining partial counties, report the oldest known component.
      # If any component has no report timestamp, do not manufacture one.
      stamp = published.any? && published.none?(&:nil?) ? published.min_by { |value| Time.iso8601(value) } : nil
      {
        "observed_votes" => rows.sum { |row| row.fetch("total_votes") },
        "raw_dem_votes" => rows.sum { |row| row.fetch("dem_votes") },
        "raw_rep_votes" => rows.sum { |row| row.fetch("rep_votes") },
        "raw_other_votes" => rows.sum { |row| row.fetch("other_votes") },
        "raw_source_ids" => ids, "raw_coverage_level" => level,
        "raw_reporting_units" => rows.size, "has_raw_source" => rows.any?,
        "raw_source_published_at" => stamp,
        "raw_source_stale" => selected.any? { |source| stale_source?(source) }
      }
    end
end
