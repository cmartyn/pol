# County matching removes geographic mix from the reported margin. It cannot
# remove within-county reporting-order bias: a deliberately wide error term
# remains. House races need a complete historical district manifest on
# independently verified unchanged lines; present-day county multiplicity is
# not proof that a county is unsplit (another contest may simply be omitted).
class ElectionNight::Observations
  TURNOUT_RATIO = 0.75
  MIN_VOTES = 5_000
  MIN_COVERAGE = 0.50
  RCV_STATES = %w[AK ME].freeze

  attr_reader :coverage

  def initialize(prior:, sources:)
    @prior, @sources = prior, sources
    @coverage = {}
  end

  def call
    # Raw totals are selected independently from model evidence. A complete
    # district aggregate can be displayed while partial counties are withheld
    # from inference; they never enter county manifests or get added together.
    raw = ElectionNight::RawResults.new(sources: @sources)
    units = raw.county_units
    baselines = {}
    house_baselines = {}
    state_manifests = raw.state_manifests
    @sources.each do |source|
      next unless source["usable"]
      Array(source.dig("baseline", "units")).each do |unit|
        baselines[[ source.fetch("state"), unit.fetch("unit_key") ]] ||= unit
      end
      Array(source.dig("baseline", "house_units")).each do |unit|
        house_baselines[[ ElectionNight::RawResults.canonical_race_key(unit.fetch("race_key")), unit.fetch("unit_key") ]] ||= unit
      end
    end
    @prior.fetch("races").filter_map do |race|
      key = race.fetch("race_key")
      source_key = ElectionNight::RawResults.canonical_race_key(key)
      rows = units.values.select { |u| u["race_key"] == source_key }
      votes = rows.sum { |u| u.fetch("total_votes") }
      historical_counties = if race["chamber"] == "house" && race["historical_house_compatible"]
        house_baselines.keys.filter_map { |race_key, county| county if race_key == source_key }.uniq.sort
      else
        []
      end
      @coverage[key] = raw.for_race(race, historical_counties: historical_counties).merge(
        "coverage_fraction" => 0.0, "reason" => "No matched historical baseline"
      )
      if rows.empty?
        @coverage[key]["reason"] = @coverage[key]["has_raw_source"] ?
          "Contest totals available; no matched county geography for direct update" : "No raw source available"
        next
      end
      unless state_manifests.key?(race["state"])
        @coverage[key]["reason"] = "Partial state source; complete race geography not established"
        next
      end
      if RCV_STATES.include?(race["state"]) || race.dig("side_a", "party") != "dem" || race.dig("side_b", "party") != "rep" || race["certain"]
        @coverage[key]["reason"] = "Returns displayed; ranked-choice, independent or uncontested outcome not conditioned"
        next
      end
      expected_counties = if race["chamber"] == "senate"
        state_manifests.fetch(race.fetch("state"))
      elsif race["historical_house_compatible"]
        house_baselines.keys.filter_map { |race_key, county| county if race_key == source_key }.uniq.sort
      else
        []
      end
      if expected_counties.empty?
        @coverage[key]["reason"] = "Current district geography lacks a verified unchanged historical district manifest; direct update withheld"
        next
      end
      unless rows.map { |row| row.fetch("unit_key") }.uniq.sort == expected_counties
        @coverage[key]["reason"] = "Race county scaffold differs from its complete geographic manifest; direct update withheld"
        next
      end
      # Senate uses the whole-state county manifest. House uses actual county
      # portions of the same district, never an inferred whole-county proxy.
      matched = rows.filter_map do |row|
        historical = if race["chamber"] == "house"
          house_baselines[[ source_key, row["unit_key"] ]]
        else
          baselines[[ race["state"], row["unit_key"] ]]
        end
        next unless historical
        if race["chamber"] == "house"
          # An uncontested historical race is not a useful partisan baseline.
          next if [ historical["dem_votes"], historical["rep_votes"] ].min.to_f / [ historical["total_votes"], 1 ].max < 0.05
        end
        historical_total = historical.fetch("dem_votes") + historical.fetch("rep_votes")
        next unless historical_total.positive?
        [ row, historical, historical_total ]
      end
      # Every component must match. House portions use a historical district
      # match only when the repository's boundary catalog verifies same lines.
      if matched.size != rows.size
        @coverage[key]["reason"] = "Split-county district or missing county baseline; direct update withheld"
        next
      end
      total_history = matched.sum { |_, _, n| n }.to_f
      expected = total_history * TURNOUT_RATIO
      reporting = matched.select { |row, _, _| row["dem_votes"] + row["rep_votes"] >= 100 }
      represented = reporting.sum { |_, _, n| n } / total_history
      counted = matched.sum { |row, _, _| row["dem_votes"] + row["rep_votes"] }.to_f
      fraction = [ counted / expected, 0.99 ].min
      @coverage[key].merge!("coverage_fraction" => represented, "counted_fraction" => fraction,
        "reason" => "Matched counties; waiting for sufficient returns", "has_baseline" => true)
      next if counted < MIN_VOTES || represented < MIN_COVERAGE || fraction < 0.15
      historical_margin = 100.0 * matched.sum { |_, h, _| h["dem_votes"] - h["rep_votes"] } / total_history
      # Expected county performance is shifted so its full-race weighted mean
      # is our frozen race prior, preserving candidate and national expectations.
      shift = race.fetch("mu") - historical_margin
      residual = reporting.sum do |row, history, history_total|
        n = row["dem_votes"] + row["rep_votes"]
        observed = 100.0 * (row["dem_votes"] - row["rep_votes"]) / n
        baseline = 100.0 * (history["dem_votes"] - history["rep_votes"]) / history_total + shift
        (observed - baseline) * n
      end / reporting.sum { |row, _, _| row["dem_votes"] + row["rep_votes"] }
      # A third-party surge invalidates a two-party transfer assumption.
      if votes.positive? && rows.sum { |r| r["other_votes"] }.to_f / votes > 0.10
        @coverage[key]["reason"] = "Third-party share exceeds the two-party observation model's limit; direct update withheld"
        next
      end
      @coverage[key]["reason"] = "County-adjusted returns; turnout and reporting-order assumptions apply"
      {
        "race_key" => key, "observed_margin" => (race.fetch("mu") + residual).clamp(-100, 100),
        "counted_fraction" => fraction,
        "sigma" => 4.0 + 10.0 * (1.0 - fraction) + 4.0 * (1.0 - represented),
        "source_ids" => reporting.map { |row, _, _| row["source_id"] }.uniq
      }
    end
  end
end
