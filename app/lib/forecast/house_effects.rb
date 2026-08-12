# Pollster house effects: how far each house's polls sit from the field, and
# how much of that gap the model is willing to act on.
#
# A residual is one poll's distance from a leave-one-out average of the same
# quantity at the same moment:
#
#   residual_p = margin_p − weighted_mean(margins of OTHER pollsters' polls of
#                the same quantity, fielded within residual_window_days of p)
#
# A pollster's raw effect is the weighted mean of its residuals, pooled across
# every quantity — the generic ballot and each race — because all of them are
# D−R margins measured against a contemporaneous average of the same thing, so
# a lean shows up the same way in all of them. That raw effect is then shrunk
# toward zero by the number of residuals behind it and clamped. Every constant
# is in `house_effects:` in config/model_params.yml.
#
# Sign convention, here and on the public page: a POSITIVE effect means the
# pollster runs more Democratic than the field, and the model subtracts it.
#
# SINGLE PASS, deliberately. House effects and averages are mutually
# dependent — the field a poll is compared against is itself made of polls
# with their own leans — and 538 resolves that by iterating to convergence.
# This computes effects once from unadjusted averages and then uses them for
# the forecast. The simplification is stated on the methodology page and in
# docs/BUILD_NOTES.md Phase 9 rather than left for a reader to discover.
class Forecast::HouseEffects
  # One poll's distance from the field. `weight` is what it carries into its
  # pollster's mean — see #residual_weight for why that is measured against
  # the run date rather than against the poll's own.
  Residual = Struct.new(:poll, :value, :weight, keyword_init: true)

  Effect = Struct.new(:pollster_id, :effect_raw, :effect_shrunk, :residual_count, :applied,
                      keyword_init: true)

  # `effects` is every pollster with at least one residual, largest magnitude
  # first. `skipped` counts why polls yielded no residual, so a run can say
  # what it did not use as well as what it did.
  Result = Struct.new(:effects, :skipped, :enabled, keyword_init: true) do
    # { pollster_id => effect } for the effects that will actually be
    # subtracted — exactly what Forecast::Averager takes.
    def lookup
      effects.select(&:applied).to_h { |effect| [ effect.pollster_id, effect.effect_shrunk ] }
    end

    def applied_count
      effects.count(&:applied)
    end

    def rows_for(model_run_id, now: Time.current)
      effects.map do |effect|
        {
          model_run_id: model_run_id, pollster_id: effect.pollster_id,
          effect_raw: effect.effect_raw, effect_shrunk: effect.effect_shrunk,
          residual_count: effect.residual_count, applied: effect.applied,
          created_at: now, updated_at: now
        }
      end
    end
  end

  # Governor races are in the schema but outside the board the model
  # forecasts, and a residual from a quantity no forecast reads is a residual
  # measured against an average nobody checks.
  MODELLED_OFFICES = Forecast::Runner::MODELLED_OFFICES

  def self.call(**options)
    new(**options).call
  end

  def initialize(as_of:)
    @as_of = as_of.to_date
    @enabled = Pol::Params.fetch!(:house_effects, :enabled)
    @min_polls_to_apply = Pol::Params.fetch!(:house_effects, :min_polls_to_apply)
    @shrinkage_k = Pol::Params.fetch!(:house_effects, :shrinkage_k).to_f
    @max_effect_pp = Pol::Params.fetch!(:house_effects, :max_effect_pp).to_f
    @residual_window_days = Pol::Params.fetch!(:house_effects, :residual_window_days)
    @residual_half_life_days = Pol::Params.fetch!(:house_effects, :residual_half_life_days).to_f
    @min_comparison_pollsters = Pol::Params.fetch!(:house_effects, :min_comparison_pollsters)
    # Unadjusted on purpose: this is the single pass. Effects are estimated
    # against the average as it stands with no house effects removed from it.
    @averager = Forecast::Averager.new(as_of: @as_of)
    @residuals = Hash.new { |hash, key| hash[key] = [] }
    @skipped = Hash.new(0)
  end

  attr_reader :as_of

  def call
    generic_ballot_polls.then { |polls| accumulate(polls, side_a: :dem, side_b: :rep) }
    races_with_polls.each { |race, polls| accumulate_race(race, polls) }

    Result.new(effects: effects, skipped: @skipped.dup, enabled: @enabled)
  end

  private
    def generic_ballot_polls
      Poll.for_generic_ballot.where(field_end: ..as_of).includes(:poll_results).to_a
    end

    def races_with_polls
      races = Race.where(office: MODELLED_OFFICES).includes(:candidates).order(:id).to_a
      polls = Poll.where(race_id: races.map(&:id), field_end: ..as_of)
                  .includes(:poll_results).group_by(&:race_id)

      races.filter_map { |race| [ race, polls[race.id] ] if polls[race.id].present? }
    end

    def accumulate_race(race, polls)
      side_a, side_b = Site::RaceSides.for(race.candidates)
      # Two sides that resolved to the same party have no margin between them
      # — Forecast::RaceModel treats such a race as unpolled, and so does this
      # rather than asking the averager to measure a side against itself.
      if side_a == side_b
        @skipped[:degenerate_sides] += polls.size
        return
      end

      accumulate(polls, side_a: side_a.to_sym, side_b: side_b.to_sym)
    end

    # One quantity's worth of residuals. Eligibility is the averager's own —
    # a poll it would refuse contributes nothing here either.
    def accumulate(polls, side_a:, side_b:)
      measured = polls.map { |poll| [ poll, @averager.measurement(poll, side_a: side_a, side_b: side_b) ] }
      @skipped[:not_measurable] += measured.count { |_, measurement| measurement.nil? }
      measured = measured.filter_map { |_, measurement| measurement }
      return if measured.empty?

      # Every eligible poll stays in `measured` — it is the field others are
      # compared against, and it is what the ambiguity test reads — but only
      # one poll per house per field period earns a residual of its own. A
      # release that publishes a two-way and a three-way version of the same
      # question is one poll, and counting it twice would inflate the
      # residual count that the shrinkage term reads as evidence. Tavern
      # Research's four Montana rows to 2026-07-27 are the live case.
      subjects(measured).each do |subject|
        residual = residual_for(subject, measured, side_a: side_a, side_b: side_b)
        @residuals[subject.poll.pollster_id] << residual if residual
      end
    end

    # Deliberately NOT applied before the ambiguity test below: a house
    # testing several opponents inside one field period is the plainest
    # evidence nobody knows who is running, and collapsing those rows first
    # would hide it. Same order, and the same reason, as Forecast::Averager.
    def subjects(measured)
      measured
        .group_by { |m| [ m.poll.pollster_id, m.poll.field_start, m.poll.field_end ] }
        .values
        .map { |group| group.max_by { |m| m.poll.id } }
        .sort_by { |m| m.poll.id }
    end

    # nil, and a counted reason, whenever this poll cannot be compared
    # honestly against its contemporaries.
    def residual_for(subject, measured, side_a:, side_b:)
      centre = subject.poll.field_end
      in_window = measured.select { |m| distance(m.poll, centre) <= @residual_window_days }

      # Phase 8's rule, applied to the comparison window instead of to the
      # averaging window. A race whose polls in this window disagree about who
      # is running has no single contest to average, so a residual measured
      # here would be part matchup difference and part house effect with no
      # way to tell which — and it would then travel into every average this
      # pollster touches. The subject's own polls are inside the test, exactly
      # as they are in the averager: one house testing seven opponents in a
      # field period is the plainest evidence nobody knows who is running.
      if @averager.distinct_matchups(in_window, side_a: side_a, side_b: side_b).size > 1
        @skipped[:ambiguous_matchup] += 1
        return nil
      end

      others = comparison_set(in_window, subject.poll.pollster_id, centre)
      # "Race-level residuals as a secondary source WHERE A RACE HAS ENOUGH
      # DISTINCT POLLSTERS TO DEFINE A MEANINGFUL AVERAGE", per the approved
      # design. Against a single other house, a residual is not a distance
      # from the field — it is the gap between two polls, half of which is the
      # other house's own lean, and it enters both pollsters' estimates equal
      # and opposite. Idaho is the live proof: two polls a week apart, 44
      # points between them, and without this rule that one pairing was the
      # largest single input to two different pollsters' published effects.
      # The generic ballot clears this bar on nearly every date; it is the
      # thin races the rule is for, and it is applied to both so there is one
      # standard for what counts as a field.
      if others.size < @min_comparison_pollsters
        @skipped[others.empty? ? :no_comparison : :thin_comparison] += 1
        return nil
      end

      total = 0.0
      weighted = 0.0
      others.each do |measurement, weight|
        total += weight
        weighted += weight * measurement.margin
      end
      if total.zero?
        @skipped[:no_comparison] += 1
        return nil
      end

      Residual.new(poll: subject.poll, value: subject.margin - (weighted / total),
                   weight: residual_weight(subject.poll))
    end

    # The field this poll is measured against: every OTHER house's polls in
    # the window, one each, paired with the weight they carry.
    #
    # One per pollster for the same reason the average keeps one — a house
    # that publishes weekly would otherwise BE the field. The Economist/YouGov
    # alone has 81 of the corpus's 559 generic-ballot polls, so without this
    # cut a good part of every other pollster's estimated lean would be a
    # measurement of how far they sit from The Economist/YouGov. The one kept
    # is the nearest in time to the poll being scored (the window runs both
    # ways, so "latest" is not the same question the averager answers), with
    # the averager's own tie-break behind it so the choice is never arbitrary.
    def comparison_set(in_window, subject_pollster_id, centre)
      in_window
        .reject { |m| m.poll.pollster_id == subject_pollster_id }
        .group_by { |m| m.poll.pollster_id }
        .values
        .map { |group| group.min_by { |m| [ distance(m.poll, centre), -m.poll.field_end.jd, -m.poll.id ] } }
        .map { |m| [ m, @averager.weight_at_age(distance(m.poll, centre), m.poll.sample_size) ] }
    end

    # Weighted mean of a pollster's residuals, shrunk and clamped.
    def effects
      @residuals.filter_map { |pollster_id, residuals|
        total = residuals.sum(&:weight)
        next if total.zero?

        raw = residuals.sum { |residual| residual.weight * residual.value } / total
        count = residuals.size
        shrunk = clamp(raw * count / (count + @shrinkage_k))

        Effect.new(pollster_id: pollster_id, effect_raw: raw, effect_shrunk: shrunk,
                   residual_count: count, applied: @enabled && count >= @min_polls_to_apply)
      }.sort_by { |effect| [ -effect.effect_shrunk.abs, effect.pollster_id ] }
    end

    def clamp(value)
      value.clamp(-@max_effect_pp, @max_effect_pp)
    end

    # How much this residual counts toward its pollster's mean: the averager's
    # weight function, aged against the RUN date rather than against the
    # poll's own, so a house's recent behaviour outweighs its behaviour last
    # year. On its own half-life, though, and not the averager's 14 days —
    # see docs/BUILD_NOTES.md Phase 9 §B. A 14-day half-life over a 20-month
    # corpus leaves RMG Research's 24 polls carrying 1.4 polls of effective
    # information while the shrinkage term, which counts polls, sees 24 and
    # barely shrinks at all. That is the confident-looking adjustment built on
    # noise this phase exists to avoid.
    def residual_weight(poll)
      recency = Math.exp(-Math.log(2) * (as_of - poll.field_end).to_i / @residual_half_life_days)
      recency * @averager.weight_at_age(0, poll.sample_size)
    end

    def distance(poll, centre)
      (poll.field_end - centre).to_i.abs
    end
end
