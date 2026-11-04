# Raw-source coverage, turnout diagnostics and evidence eligibility are distinct.
# Only complete independently matched county snapshots can condition the model.
class ElectionNight::Observations
  MIN_VOTES = 5_000
  MIN_COVERAGE = 0.50
  RCV_STATES = %w[AK ME].freeze

  attr_reader :coverage, :county_rejections

  def initialize(prior:, sources:, historical: {})
    @prior, @sources, @historical = prior, sources, historical
    @coverage = {}
  end

  def call
    prepare_history
    @raw = ElectionNight::RawResults.new(sources: @sources, county_identity: @identity)
    @county_rejections = @raw.county_rejections
    # An inferred publisher county count cannot replace an independently
    # verified named roster. Changed current geography must fail the match.
    @state_manifests = @raw.state_manifests.merge(@historical.fetch("state_manifests", {}).transform_values(&:sort))
    @prior.fetch("races").filter_map { |race| observation(race) }
  end

  private
    def prepare_history
      legacy = @sources.select { |s| s["usable"] }.flat_map do |source|
        %w[units house_units].flat_map do |kind|
          Array(source.dig("baseline", kind)).map { |unit| unit.merge("state" => source.fetch("state"), "baseline_kind" => kind) }
        end
      end
      frozen = %w[units house_units].flat_map { |kind| @historical.fetch(kind, []).map { |unit| unit.merge("baseline_kind" => kind) } }
      @identity = ElectionNight::CountyIdentity.new(frozen + legacy)
      @baselines, @house_baselines = {}, {}
      # Official archives and the frozen bundle share a verified identity join.
      (legacy + frozen).each do |unit|
        unit = @identity.normalize(unit.fetch("state"), unit)
        if unit["baseline_kind"] == "house_units"
          @house_baselines[[ canonical(unit.fetch("race_key")), unit.fetch("unit_key") ]] ||= unit
        else
          @baselines[[ unit.fetch("state"), unit.fetch("unit_key") ]] ||= unit
        end
      end
      @current_line_totals = @historical.fetch("house_totals_current_lines", []).index_by { |row| canonical(row.fetch("race_key")) }
      @midterm = @historical.fetch("turnout_2022", []).select { |row| row.fetch("race_key").end_with?("-S") }
        .group_by { |row| row.fetch("state") }
    end

    def canonical(key) = ElectionNight::RawResults.canonical_race_key(key)

    def expected_counties(race)
      if race["chamber"] == "senate"
        @state_manifests.fetch(race.fetch("state"), [])
      elsif race["historical_house_compatible"]
        @house_baselines.keys.filter_map { |race_key, county| county if race_key == canonical(race.fetch("race_key")) }.sort
      else
        []
      end
    end

    def observation(race)
      key = race.fetch("race_key")
      expected = expected_counties(race)
      coverage = @coverage[key] = @raw.for_race(race, historical_counties: expected).merge(
        "coverage_fraction" => 0.0, "reason" => "No matched historical baseline")
      coverage["outstanding_votes"] = aggregate_outstanding(race, coverage)
      if RCV_STATES.include?(race["state"])
        coverage["reason"] = "Returns displayed; ranked-choice rounds are not modeled"
        return
      end
      rows = @raw.matched_counties(key, expected_counties: expected)
      unless rows
        coverage["reason"] = if !coverage["has_raw_source"]
          "No raw source available"
        elsif @raw.county_units.values.none? { |row| row["race_key"] == canonical(key) }
          "Contest totals available; no matched county geography for direct update"
        elsif race["chamber"] == "senate" && expected.empty?
          "Partial state source; complete race geography not established"
        elsif expected.empty?
          "Current district geography lacks a verified unchanged historical district manifest; direct update withheld"
        else
          "Race county scaffold differs from its complete geographic manifest; direct update withheld"
        end
        return
      end
      matched = rows.filter_map do |row|
        history = race["chamber"] == "house" ? @house_baselines[[ canonical(key), row["unit_key"] ]] : @baselines[[ race["state"], row["unit_key"] ]]
        next unless history
        total = history.fetch("dem_votes") + history.fetch("rep_votes")
        [ row, history, total ] if total.positive?
      end
      if matched.size != rows.size
        coverage["reason"] = "Split-county district or missing county baseline; direct update withheld"
        return
      end
      estimate = ElectionNight::OutstandingVotes.new(matched: matched, race_prior: race, midterm_totals: midterm_totals(race, expected)).call
      model_ids = rows.map { |row| row.fetch("source_id") }.uniq
      # The visible remaining estimate must subtract the same counted votes
      # shown in the table. A fallback may independently supply model evidence,
      # but cannot replace this diagnostic with a different count snapshot.
      if model_ids.sort == coverage.fetch("raw_source_ids").sort
        coverage["outstanding_votes"] = public_estimate(estimate, "county")
      end
      coverage.merge!("coverage_fraction" => estimate.fetch("represented_fraction"),
        "counted_fraction" => estimate.fetch("counted_fraction"), "model_source_ids" => model_ids)
      if race.dig("side_a", "party") != "dem" || race.dig("side_b", "party") != "rep" || race["certain"]
        coverage["reason"] = "Returns displayed; independent or uncontested outcome not conditioned"
        return
      end
      # A partisan county is valid evidence. The historical race as a whole
      # must have a contested major-party baseline.
      historical_total = matched.sum { |_, history, _| history.fetch("total_votes") }
      if race["chamber"] == "house" && %w[dem_votes rep_votes].any? { |party| matched.sum { |_, history, _| history.fetch(party) }.to_f / historical_total < 0.05 }
        coverage["reason"] = "Historical House race lacks a contested partisan baseline; direct update withheld"
        return
      end
      coverage.merge!("has_baseline" => true, "reason" => "Matched counties; waiting for sufficient returns")
      return if estimate.fetch("counted_two_party_votes") < MIN_VOTES || estimate.fetch("represented_fraction") < MIN_COVERAGE || estimate.fetch("counted_fraction_low") < 0.15
      if rows.sum { |row| row.fetch("other_votes") }.to_f / estimate.fetch("counted_votes") > 0.10
        coverage["reason"] = "Third-party share exceeds the partisan observation model's limit; direct update withheld"
        return
      end
      coverage["reason"] = "County-adjusted remaining-vote projection; turnout and reporting-order assumptions apply"
      estimate.fetch("measurement").merge("race_key" => key)
    end

    def midterm_totals(race, expected)
      # 2022–2024 House boundary compatibility has not been verified here.
      return {} unless race["chamber"] == "senate"
      manifest = @historical.fetch("turnout_state_manifests", {})[race.fetch("state")]
      return {} unless manifest
      keys = manifest.map { |key| @identity.normalize(race.fetch("state"), { "unit_key" => key }).fetch("unit_key") }
      return {} unless keys.sort == expected.sort
      rows = @midterm.fetch(race.fetch("state"), []).map { |row| @identity.normalize(race.fetch("state"), row) }
      return {} unless rows.none? { |row| row["historical_county_match"] == false } && rows.map { |row| row.fetch("unit_key") }.sort == expected.sort
      rows.to_h { |row| [ row.fetch("unit_key"), row.fetch("total_votes") ] }
    end

    def aggregate_outstanding(race, coverage)
      return unless coverage["has_raw_source"] && %w[county contest].include?(coverage["raw_coverage_level"]) && !RCV_STATES.include?(race["state"])
      history = if race["chamber"] == "house"
        @current_line_totals[canonical(race.fetch("race_key"))]
      elsif @historical.fetch("state_manifests", {}).key?(race.fetch("state"))
        rows = @historical.fetch("units").select { |row| row["state"] == race["state"] }
        %w[dem_votes rep_votes other_votes total_votes].to_h { |field| [ field, rows.sum { |row| row.fetch(field) } ] }.merge("unit_key" => "CONTEST")
      end
      return unless history
      row = { "unit_key" => "CONTEST", "dem_votes" => coverage.fetch("raw_dem_votes"), "rep_votes" => coverage.fetch("raw_rep_votes"),
        "other_votes" => coverage.fetch("raw_other_votes"), "total_votes" => coverage.fetch("observed_votes") }
      estimate = ElectionNight::OutstandingVotes.new(matched: [ [ row, history, history.fetch("dem_votes") + history.fetch("rep_votes") ] ], race_prior: race).call
      public_estimate(estimate, "contest")
    end

    def public_estimate(estimate, scope)
      estimate.except("units", "measurement").merge("geography_scope" => scope,
        "turnout_basis" => estimate.fetch("midterm_anchored_units").positive? ? "Matched 2022 midterm county votes" :
          (scope == "county" ? "75% of matched 2024 county votes" : "75% of 2024 presidential votes on current boundaries"))
    end
end
