# How much a partisan-sponsored poll's margin should be discounted before the
# incl_internals variant reads it, in percentage points toward the non-sponsor
# party.
#
# The estimate is empirical where the corpus can support one and a prior where
# it cannot. A flagged poll is paired with the unflagged polls of the same
# quantity — same race, same matchup, or the generic ballot — whose field end
# lands within pair_window_days of its own; the pair's gap is how much
# friendlier the flagged poll ran toward its sponsor than the field it shares
# a moment with. The cycle-wide estimate is the recency-weighted mean of those
# gaps, shrunk toward internals.prior_shift by pair count, exactly the
# shrinkage shape house effects use: an estimate from n pairs keeps
# n/(n + shrinkage_k) of its own signal.
#
# Only DEM- and REP-flagged polls inform the estimate, and margins are read
# dem − rep: a flagged poll of a race without both major-party results (the
# I−R races) measures nothing this estimate can use, and Averager#measurement
# already says so by returning nil. IND/OTH-flagged polls take the weight
# penalty in the averager but neither inform nor receive the shift — a
# sponsor without a side has no direction to discount toward.
#
# Computed once per model run from the run's own poll snapshot and recorded in
# params_snapshot, so every run can say what shift it applied and why.
class Forecast::Internals
  Estimate = Struct.new(:shift, :prior, :empirical_mean, :pair_count, keyword_init: true) do
    def to_snapshot
      { "shift" => shift.round(4), "prior" => prior,
        "empirical_mean" => empirical_mean&.round(4), "pair_count" => pair_count }
    end
  end

  DIRECTIONS = { "dem" => 1.0, "rep" => -1.0 }.freeze

  def self.estimate(as_of:)
    new(as_of: as_of).estimate
  end

  def initialize(as_of:)
    @as_of = as_of.to_date
    @prior = Pol::Params.fetch!(:internals, :prior_shift).to_f
    @pair_window_days = Pol::Params.fetch!(:internals, :pair_window_days)
    @shrinkage_k = Pol::Params.fetch!(:internals, :shrinkage_k).to_f
    # Pair gaps age on the house-effects half-life, not the averager's 14
    # days, and for the same reason: this is a slow-moving property of how
    # sponsors release polls, not a reading of any race today.
    @half_life_days = Pol::Params.fetch!(:house_effects, :residual_half_life_days).to_f
    # Unadjusted and internals-excluded on purpose: the field a flagged poll
    # is compared against must not itself contain flagged polls.
    @averager = Forecast::Averager.new(as_of: @as_of)
  end

  attr_reader :as_of

  def estimate
    gaps = flagged_polls.filter_map { |poll| pair_gap(poll) }
    return Estimate.new(shift: @prior, prior: @prior, empirical_mean: nil, pair_count: 0) if gaps.empty?

    total = gaps.sum { |gap| gap[:weight] }
    mean = gaps.sum { |gap| gap[:weight] * gap[:value] } / total
    count = gaps.size

    Estimate.new(
      shift: blend(mean, count),
      prior: @prior,
      empirical_mean: mean,
      pair_count: count
    )
  end

  private
    # The judgment of this whole class in one line: how far n pairs of
    # evidence pull the shift off its prior. Same shape as house-effect
    # shrinkage so the two adjustments answer to one philosophy.
    def blend(mean, count)
      @prior + ((mean - @prior) * count / (count + @shrinkage_k))
    end

    def flagged_polls
      Poll.model_corpus.where(partisan: DIRECTIONS.keys)
          .where(field_end: ..as_of).includes(:poll_results)
    end

    # { value:, weight: } — this flagged poll's sponsor-ward excess over its
    # unflagged contemporaries, or nil when it has none to be measured
    # against. One peer per pollster, nearest in time, the house-effects
    # comparison discipline: a house that publishes weekly must not BE the
    # field.
    def pair_gap(poll)
      flagged = @averager.measurement(poll)
      return nil if flagged.nil?

      peers = peer_measurements(poll)
      return nil if peers.empty?

      total = 0.0
      weighted = 0.0
      peers.each do |measurement, weight|
        total += weight
        weighted += weight * measurement.margin
      end
      return nil if total.zero?

      direction = DIRECTIONS.fetch(poll.partisan)
      {
        value: (flagged.margin - (weighted / total)) * direction,
        weight: recency_weight(poll)
      }
    end

    def peer_measurements(poll)
      unflagged_by_quantity(poll.race_id, poll.matchup_key)
        .select { |peer| (peer.field_end - poll.field_end).to_i.abs <= @pair_window_days }
        .filter_map { |peer| @averager.measurement(peer) }
        .group_by { |measurement| measurement.poll.pollster_id }
        .values
        .map { |group| group.min_by { |m| [ (m.poll.field_end - poll.field_end).to_i.abs, -m.poll.id ] } }
        .map { |m| [ m, @averager.weight_at_age((m.poll.field_end - poll.field_end).to_i.abs, m.poll.sample_size) ] }
    end

    def unflagged_by_quantity(race_id, matchup_key)
      @unflagged ||= Poll.model_corpus.partisan_none
                         .where(field_end: ..as_of).includes(:poll_results)
                         .group_by { |poll| [ poll.race_id, poll.matchup_key ] }
      @unflagged.fetch([ race_id, matchup_key ], [])
    end

    def recency_weight(poll)
      Math.exp(-Math.log(2) * (as_of - poll.field_end).to_i / @half_life_days)
    end
end
