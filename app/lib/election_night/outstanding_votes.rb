require "digest"

# An assumption-based remaining-candidate-vote model, not a ballot inventory.
# Geographic matching, source validity, and observation eligibility are the
# caller's responsibility. Provider completion estimates are never read.
class ElectionNight::OutstandingVotes
  VERSION = "county-outstanding-v1".freeze
  FALLBACK_RATIO = 0.75
  SHARED_TURNOUT_SIGMA = 0.20
  FALLBACK_LOCAL_SIGMA = 0.25
  MIDTERM_LOCAL_SIGMA = 0.18
  MIN_MARGIN_SIGMA = 4.0
  MAX_UNIT_VOTES = 1_000_000_000_000
  SQRT_TWO = Math.sqrt(2.0)

  def initialize(matched:, race_prior:, midterm_totals: {}, seed: 5352026, draws: 256)
    @draws = Integer(draws)
    raise ArgumentError, "draws must be between 64 and 4096" unless (64..4096).cover?(@draws)
    @mu = Float(race_prior.fetch("mu"))
    raise ArgumentError, "prior margin must be finite and within -100..100" unless @mu.finite? && @mu.between?(-100, 100)
    salt = Digest::SHA256.hexdigest(race_prior.fetch("race_key")).slice(0, 16).to_i(16)
    @seed = Integer(seed) ^ salt
    raise ArgumentError, "matched geography is required" unless matched.is_a?(Array) && matched.any?
    @units = matched.map do |row, history, historical_two_party|
      current, past = counts(row), counts(history)
      key = row.fetch("unit_key")
      raise ArgumentError, "mismatched reporting geography" unless key.is_a?(String) && !key.empty? && key == history.fetch("unit_key")
      raise ArgumentError, "historical two-party denominator mismatch" unless historical_two_party == past[:two_party] && historical_two_party.positive?
      midterm = midterm_totals[key]
      midterm = vote_count(midterm) unless midterm.nil?
      raise ArgumentError, "midterm anchor must be positive" if midterm && !midterm.positive?
      anchor = midterm || past[:total] * FALLBACK_RATIO
      overshoot = [ Math.log([ current[:total] / anchor.to_f, 1.0 ].max), 0.0 ].max
      local_sigma = midterm ? MIDTERM_LOCAL_SIGMA : FALLBACK_LOCAL_SIGMA
      sigma = Math.hypot(SHARED_TURNOUT_SIGMA, local_sigma) + 0.5 * overshoot
      # No raw count establishes completion. If the anchor is exhausted, keep
      # an explicit unresolved tail, and expand it when turnout overshoots.
      point = [ anchor.to_f, current[:total] * (1.10 + 0.10 * overshoot) ].max
      { key: key, current: current, history: past, anchor: anchor.to_f, point: point,
        sigma: sigma, overshoot: overshoot.positive?, midterm: !midterm.nil?, source_id: row["source_id"] }
    end.sort_by { |unit| unit[:key] }
    raise ArgumentError, "duplicate reporting geography" unless @units.map { |unit| unit[:key] }.uniq.size == @units.size
    unknown = midterm_totals.keys - @units.map { |unit| unit[:key] }
    raise ArgumentError, "midterm geography not present in matched units" if unknown.any?
    prepare_margins
  end

  def call
    random = Random.new(@seed)
    totals, margins = [], []
    unit_samples = @units.to_h { |unit| [ unit[:key], [] ] }
    point_total = @units.sum { |unit| unit[:point] }
    point_margin = projected_margin(@units.map { |unit| unit[:point] })
    @draws.times do
      shared_turnout = normal(random)
      reporting_bias = normal(random) * @reporting_bias_sigma
      projected = @units.map do |unit|
        shared_weight = SHARED_TURNOUT_SIGMA / unit[:sigma]
        z = shared_weight * shared_turnout + Math.sqrt(1.0 - shared_weight**2) * normal(random)
        total = turnout_draw(unit, z)
        unit_samples.fetch(unit[:key]) << total
        total
      end
      totals << projected.sum
      margins << projected_margin(projected, random: random, reporting_bias: reporting_bias) if @reporting.any?
    end
    result = summary(totals, point_total, @counted).merge(
      "model_version" => VERSION, "experimental" => true, "interval_level" => 0.90,
      "interval_kind" => "assumption_based_scenarios", "vote_denominator" => "all_candidate_votes",
      "point_kind" => "historical_anchor_with_unresolved_tail",
      "margin_denominator" => "all_candidate_votes", "counted_two_party_votes" => @counted_two_party,
      "represented_fraction" => @represented, "midterm_anchored_units" => @units.count { |unit| unit[:midterm] },
      "fallback_units" => @units.count { |unit| !unit[:midterm] },
      "turnout_overshoot_units" => @units.count { |unit| unit[:overshoot] },
      "units" => @units.map do |unit|
        summary(unit_samples.fetch(unit[:key]), unit[:point], unit[:current][:total]).merge(
          "unit_key" => unit[:key], "turnout_anchor" => unit[:anchor],
          "turnout_basis" => unit[:midterm] ? "matched_2022_total" : "2024_total_times_0.75",
          "turnout_overshoot" => unit[:overshoot])
      end,
      "measurement" => nil
    )
    if @reporting.any?
      error = Math.sqrt(margins.sum { |margin| (margin - point_margin)**2 } / margins.size)
      result["measurement"] = {
        "observed_margin" => point_margin, "sigma" => [ error, MIN_MARGIN_SIGMA ].max,
        "counted_fraction" => result.fetch("counted_fraction"),
        "source_ids" => @reporting.filter_map { |unit| unit[:source_id] }.uniq.sort,
        "margin_low" => [ quantile(margins, 0.05), point_margin ].min,
        "margin_high" => [ quantile(margins, 0.95), point_margin ].max
      }
    end
    result
  end

  private
    def vote_count(value)
      unless value.is_a?(Integer) && value.between?(0, MAX_UNIT_VOTES)
        raise ArgumentError, "vote counts must be nonnegative integers no larger than one trillion per unit"
      end
      value
    end

    def counts(row)
      dem, rep, total = %w[dem_votes rep_votes total_votes].map { |key| vote_count(row.fetch(key)) }
      other = vote_count(row.fetch("other_votes", total - dem - rep))
      raise ArgumentError, "candidate counts do not reconcile" unless dem + rep + other == total
      { dem: dem, rep: rep, total: total, two_party: dem + rep }
    end

    def prepare_margins
      shift = historical_margin_shift
      @counted = @units.sum { |unit| unit[:current][:total] }
      @counted_two_party = @units.sum { |unit| unit[:current][:two_party] }
      @reporting = @units.select { |unit| unit[:current][:two_party] >= 100 }
      @represented = @reporting.sum { |unit| unit[:history][:two_party] }.to_f / @units.sum { |unit| unit[:history][:two_party] }
      @units.each do |unit|
        h, c = unit.values_at(:history, :current)
        unit[:baseline_margin] = (100.0 * (h[:dem] - h[:rep]) / h[:total] + shift).clamp(-100, 100)
        unit[:residual] = c[:total].positive? ? 100.0 * (c[:dem] - c[:rep]) / c[:total] - unit[:baseline_margin] : 0.0
        unit[:weight] = [ c[:total], unit[:anchor] ].min
      end
      center = weighted_median(@reporting)
      weight = @reporting.sum { |unit| unit[:weight] }
      swing = weight.positive? ? @reporting.sum { |unit| unit[:residual].clamp(center - 20.0, center + 20.0) * unit[:weight] } / weight : 0.0
      spread = weight.positive? ? Math.sqrt(@reporting.sum { |unit| (unit[:residual] - swing)**2 * unit[:weight] } / weight) : 0.0
      @reporting_bias_sigma = 8.0 + 8.0 * (1.0 - @represented) + 0.5 * spread
      @units.each do |unit|
        n = unit[:current][:two_party]
        reliability = n >= 100 ? n.to_f / (n + 1000.0) : 0.0
        unit[:remaining_margin] = (unit[:baseline_margin] + swing + reliability * (unit[:residual] - swing)).clamp(-100, 100)
      end
    end

    def historical_margin_shift
      total = @units.sum { |unit| unit[:anchor] }
      lower, upper = -200.0, 200.0
      # A simple additive shift followed by clipping no longer averages to the
      # race prior when a polarized county hits +/-100. Solve after bounding.
      48.times do
        shift = (lower + upper) / 2.0
        margin = @units.sum do |unit|
          h = unit[:history]
          unit[:anchor] * (100.0 * (h[:dem] - h[:rep]) / h[:total] + shift).clamp(-100, 100)
        end / total
        return shift if (margin - @mu).abs < 1e-12
        if margin < @mu then lower = shift else upper = shift end
      end
      (lower + upper) / 2.0
    end

    def weighted_median(units)
      return 0.0 if units.empty?
      ordered = units.sort_by { |unit| unit[:residual] }
      half = ordered.sum { |unit| unit[:weight] } / 2.0
      cumulative = 0.0
      ordered.each_with_index do |unit, index|
        cumulative += unit[:weight]
        return (unit[:residual] + ordered.fetch(index + 1, unit)[:residual]) / 2.0 if cumulative == half
        return unit[:residual] if cumulative > half
      end
    end

    def projected_margin(totals, random: nil, reporting_bias: 0.0)
      difference = @units.each_with_index.sum do |unit, index|
        current = unit[:current]
        margin = unit[:remaining_margin]
        if random
          progress = current[:total] / totals[index]
          margin += reporting_bias + normal(random) * (6.0 + 6.0 * (1.0 - progress))
        end
        current[:dem] - current[:rep] + (totals[index] - current[:total]) * margin.clamp(-100, 100) / 100.0
      end
      (100.0 * difference / totals.sum).clamp(-100, 100)
    end

    def turnout_draw(unit, z)
      counted = unit[:current][:total]
      if counted.positive?
        lower = Math.log(counted / unit[:anchor]) / unit[:sigma]
        # Work in log survival probabilities to avoid rounding an overshoot
        # to a zero-width tail (and hence fabricated count completion).
        z = inverse_log_tail(log_tail(lower) + log_tail(z))
      end
      [ unit[:anchor] * Math.exp(unit[:sigma] * z), counted.to_f.next_float ].max
    end

    def log_tail(z)
      return Math.log(0.5 * Math.erfc(z / SQRT_TWO)) if z < 8.0
      # Mills-ratio asymptotic expansion keeps extreme lower bounds finite.
      inverse = 1.0 / z**2
      -0.5 * z**2 - Math.log(z) - 0.5 * Math.log(2.0 * Math::PI) + Math.log(1.0 - inverse + 3.0 * inverse**2 - 15.0 * inverse**3)
    end

    def inverse_log_tail(target)
      low, high = -40.0, [ 40.0, Math.sqrt(-2.0 * target) + 2.0 ].max
      32.times do
        middle = (low + high) / 2.0
        if log_tail(middle) > target then low = middle else high = middle end
      end
      (low + high) / 2.0
    end

    def normal(random)
      Math.sqrt(-2.0 * Math.log([ random.rand, Float::MIN ].max)) * Math.cos(2.0 * Math::PI * random.rand)
    end

    def quantile(values, probability)
      sorted = values.sort
      position = probability * (sorted.size - 1)
      low = position.floor
      sorted[low] + (sorted[position.ceil] - sorted[low]) * (position - low)
    end

    def summary(samples, point, counted)
      low = [ quantile(samples, 0.05), point ].min
      high = [ quantile(samples, 0.95), point ].max
      {
        "counted_votes" => counted, "projected_total_votes" => point,
        "projected_total_votes_low" => low, "projected_total_votes_high" => high,
        "remaining_votes" => point - counted, "remaining_votes_low" => low - counted, "remaining_votes_high" => high - counted,
        "counted_fraction" => counted / point, "counted_fraction_low" => counted / high, "counted_fraction_high" => counted / low
      }
    end
end
