require "time"

# Select one coherent raw vote total per race. Aggregate totals and county
# portions represent the same ballots and must never be added together.
# These display choices do not establish eligibility for model conditioning.
class ElectionNight::RawResults
  attr_reader :county_units, :state_manifests, :county_rejections

  def self.canonical_race_key(key)
    key.sub(/\A(AK|DE|ND|SD|VT|WY)-(?:00|01|AL)\z/, '\1-AL')
  end

  def initialize(sources:, county_identity: nil)
    # Retained snapshots remain available, but cannot shadow a healthy feed
    # merely because their registry entry comes first.
    # A later export-generation or fetch timestamp is not evidence that its
    # race counts are newer. Without comparable count-update semantics, a
    # healthy primary keeps priority even when its report timestamp is old.
    @sources = sources.select { |source| source["usable"] }.each_with_index
      .sort_by { |source, index| [ stale_source?(source) ? 1 : 0, source.fetch("priority", 0), index ] }.map(&:first)
    @county_units, @state_manifests, @by_source, @county_rejections = {}, {}, [], []
    @sources.each do |source|
      counties, aggregates, original_keys, duplicate_keys = {}, {}, {}, {}
      Array(source.dig("results", "units")).each do |unit|
        next unless valid_counts?(unit)
        unit = unit.merge("race_key" => self.class.canonical_race_key(unit.fetch("race_key")))
        identity = [ unit.fetch("race_key"), unit.fetch("unit_key") ]
        if aggregate?(unit) || source["aggregate_only"]
          aggregates[unit.fetch("race_key")] ||= unit.merge("source_id" => source.fetch("id"))
        elsif county?(unit)
          original_key = unit.fetch("unit_key")
          unit = county_identity.normalize(source.fetch("state"), unit) if county_identity
          identity = [ unit.fetch("race_key"), unit.fetch("unit_key") ]
          if counties.key?(identity)
            duplicate_keys[identity] ||= [ original_keys.fetch(identity) ]
            duplicate_keys[identity] << original_key
          else
            original_keys[identity] = original_key
            counties[identity] = unit.merge("source_id" => source.fetch("id"))
          end
        end
      end
      Array(source.dig("results", "aggregate_units")).each do |unit|
        next unless valid_counts?(unit)
        unit = unit.merge("race_key" => self.class.canonical_race_key(unit.fetch("race_key")))
        aggregates[unit.fetch("race_key")] ||= unit.merge("source_id" => source.fetch("id"), "aggregate_only" => true)
      end
      # Two rows that normalize to one county might be duplicate reports or
      # disjoint portions. Neither summing nor keeping the first is justified.
      # Withhold this source's entire race geography so a reduced list cannot
      # masquerade as a complete historical manifest. A separately validated
      # contest aggregate and other publishers remain usable.
      ambiguous_races = duplicate_keys.keys.map(&:first).uniq
      counties.delete_if { |(race_key, _), _| ambiguous_races.include?(race_key) }
      duplicate_keys.each do |(race_key, unit_key), names|
        @county_rejections << { "source_id" => source.fetch("id"), "race_key" => race_key,
          "unit_key" => unit_key, "source_unit_keys" => names,
          "reason" => "Multiple reporting rows resolve to the same county; source race geography withheld" }
      end
      counties.each { |identity, unit| @county_units[identity] ||= unit }
      manifest = counties.values.map { |unit| unit.fetch("unit_key") }.uniq.sort
      statewide = ambiguous_races.empty? && source["expected_counties"].to_i.positive? && manifest.size == source["expected_counties"].to_i
      @state_manifests[source.fetch("state")] ||= manifest if statewide
      @by_source << { source: source, counties: counties.values.group_by { |unit| unit.fetch("race_key") },
        aggregates: aggregates, statewide: statewide, manifest: manifest }
    end
  end

  def for_race(race, historical_counties: [])
    key = self.class.canonical_race_key(race.fetch("race_key"))
    # A healthy primary aggregate precedes a fallback's county detail. The
    # priority is explicit; a source's geography cannot silently override it.
    selection_groups.each do |entries|
      complete = entries.find { |entry| complete_county?(entry, key, race, historical_counties) }
      return summarize(complete[:counties].fetch(key), "county") if complete
      if (entry = entries.find { |candidate| candidate[:aggregates].key?(key) })
        return summarize([ entry[:aggregates].fetch(key) ], "contest")
      end
    end
    rows = @county_units.values.select { |row| row["race_key"] == key }
    summarize(rows, rows.any? ? "partial" : "none")
  end

  # Direct evidence comes from one coherent publisher snapshot. Never fill a
  # primary's missing counties with overlapping fallback versions and pretend
  # that the combined list is a complete race report.
  def matched_counties(race_key, expected_counties:)
    key = self.class.canonical_race_key(race_key)
    expected = expected_counties.sort
    entry = @by_source.find do |candidate|
      rows = candidate[:counties][key]
      rows && expected.any? && rows.none? { |row| row["historical_county_match"] == false } &&
        rows.map { |row| row.fetch("unit_key") }.sort == expected
    end
    entry && entry[:counties].fetch(key)
  end

  private
    def selection_groups
      @by_source.group_by { |entry| [ stale_source?(entry[:source]) ? 1 : 0, entry[:source].fetch("priority", 0) ] }.values
    end

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
      return true if historical_counties.any? && rows.none? { |row| row["historical_county_match"] == false } &&
        rows.map { |row| row.fetch("unit_key") }.sort == historical_counties.sort
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
        "raw_source_stale" => selected.any? { |source| stale_source?(source) },
        "raw_source_fallback" => selected.any? { |source| source["source_role"] == "fallback" }
      }
    end
end
