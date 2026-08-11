# One race's central estimate: who the two sides are, what the fundamentals say
# about them, what the polls say, and the blend of the two that the simulator
# draws around. Margins are side A minus side B in percentage points.
#
# Every constant comes from config/model_params.yml.
class Forecast::RaceModel
  # A side of the contest. `party` decides which poll column it reads and which
  # of p_dem_win / p_rep_win / p_other_win its wins land in; `caucus` decides
  # which pile it joins when the Senate is counted, and is :uncommitted for an
  # independent who has not said (Dan Osborn in Nebraska is the live case).
  Side = Struct.new(:party, :caucus, :name, keyword_init: true) do
    def dem?
      party == :dem
    end

    def rep?
      party == :rep
    end
  end

  MAJOR_PARTIES = %w[dem rep].freeze
  CHAMBERS = { "senate" => :senate, "house" => :house }.freeze

  def initialize(race:, national_env:, averager:, polls: nil)
    @race = race
    @national_env = national_env
    @averager = averager
    @polls = polls
  end

  attr_reader :race, :national_env

  # The two sides, resolved from the candidate list. side_a is the Democrat
  # where one is running; where none is, an independent takes the anti-
  # Republican slot (Idaho, Nebraska and South Dakota all look like this in
  # 2026). Where a party's nominee simply is not settled yet — Minnesota has
  # neither — the side keeps the party and carries no name: the contest is
  # still a Democrat against a Republican, we just cannot say who.
  def side_a
    @side_a ||= begin
      democrat = top_candidate("dem")
      if democrat
        side_for(democrat)
      elsif (independent = top_minor_candidate)
        side_for(independent)
      else
        Side.new(party: :dem, caucus: :dem, name: nil)
      end
    end
  end

  def side_b
    @side_b ||= begin
      republican = top_candidate("rep")
      if republican
        side_for(republican)
      elsif (independent = top_minor_candidate(except: side_a.name))
        side_for(independent)
      else
        Side.new(party: :rep, caucus: :rep, name: nil)
      end
    end
  end

  def average
    @average ||= @averager.for_race(race, side_a: side_a.party, side_b: side_b.party, polls: @polls)
  end

  def polled?
    average.polled?
  end

  # Senate: the state's partisan lean, shifted by the national environment and
  # by incumbency. House: the district's 2024 result, shifted by the swing in
  # the national environment since 2024.
  #
  # For the handful of races where side A is an independent rather than a
  # Democrat, this prior is used unchanged as a proxy: the state's Democratic
  # lean stands in for the anti-Republican vote. That is an approximation and a
  # documented one (docs/BUILD_NOTES.md Phase 3) — inventing a separate
  # independent-specific prior would be inventing a number nothing supports.
  def prior
    race.house? ? house_prior : senate_prior
  end

  # w = min(1, W / weight_saturation): how far the polls have earned their way
  # in. Zero when the race has no usable polls, in which case mu is the prior.
  def blend_weight
    return 0.0 unless polled?

    [ 1.0, average.weight / Pol::Params.fetch!(:blend, :weight_saturation) ].min
  end

  def mu
    return prior unless polled?

    weight = blend_weight
    (weight * average.mean_margin) + ((1.0 - weight) * prior)
  end

  # Election-day-equivalent standard deviation of this race's own error, on top
  # of the shared national error. The simulator applies the time multiplier.
  def sigma_key
    return :sigma_district if race.house?

    polled? ? :sigma_state_polled : :sigma_state_unpolled
  end

  def sigma
    Pol::Params.fetch!(:error_model, sigma_key)
  end

  # Non-nil when the outcome is not in doubt: an uncontested race has one
  # winner in every simulated world and takes no noise.
  def certain_side
    return nil unless race.uncontested?

    # Flagged uncontested with no party recorded is an incomplete flag, not a
    # certainty. Simulating the race is the safe reading; inventing a winner
    # is not.
    party = race.uncontested_party
    return nil if party.blank?
    return side_a if party == side_a.party.to_s
    return side_b if party == side_b.party.to_s

    candidate = top_candidate(party)
    candidate ? side_for(candidate) : Side.new(party: party.to_sym, caucus: caucus_for(party, nil), name: nil)
  end

  def to_entry
    Forecast::Simulator::Entry.new(
      race_id: race.id,
      # A governor race has no chamber to be counted into, and quietly filing
      # one under "senate" would corrupt a control probability. The runner
      # never hands one over; if that changes, this says so.
      chamber: CHAMBERS.fetch(race.office),
      mu: mu,
      sigma: sigma,
      weight: average.weight,
      side_a: side_a,
      side_b: side_b,
      certain: certain_side
    )
  end

  private
    def senate_prior
      lean = race.lean || 0.0
      lean + national_env + (Pol::Params.fetch!(:fundamentals, :incumbency_adj) * incumbent_direction)
    end

    # +1 for a Democratic incumbent on the ballot, −1 for a Republican, 0 for
    # an open seat. Phase 2 sets open_seat true exactly when the sitting
    # senator is not on the November ballot, which is the only signal that
    # covers South Carolina: the appointed incumbent is running, but the
    # Republican nomination is unsettled so no candidate row carries the
    # incumbent flag. An appointed incumbent seeking the seat counts as an
    # incumbent (Florida, Ohio, South Carolina); an appointee who cannot run
    # does not (Oklahoma, where open_seat is true).
    def incumbent_direction
      return 0 if race.open_seat?

      party_direction(race.incumbent_party)
    end

    def house_prior
      # baseline_margin is the district's 2024 two-party margin; Phase 2's
      # seeder guarantees one for all 435 districts, imputing where a major
      # party did not field a candidate.
      baseline = race.baseline_margin || 0.0
      swing = national_env - Pol::Params.fetch!(:fundamentals, :house_national_margin_2024)
      baseline + swing + open_seat_term
    end

    # v1 seeds no 2026 House incumbency or retirements — Phase 2 read the 2024
    # results page, which carries neither — so race.open_seat is false for
    # every district and this term is always zero today. It is written out in
    # full so that the day a Phase 6 admin (or a later scraper) marks a
    # district open, the model starts docking the retiring party's incumbency
    # advantage without a code change. Senate open seats do not come through
    # here: they are already handled by incumbent_direction going to zero.
    def open_seat_term
      return 0.0 unless race.open_seat?

      -Pol::Params.fetch!(:fundamentals, :open_seat_adj) * party_direction(race.incumbent_party)
    end

    def party_direction(party)
      case party
      when "dem" then 1
      when "rep" then -1
      else 0
      end
    end

    def candidates
      @candidates ||= race.candidates.to_a
    end

    # At most one candidate per party per race in the seeded data; the id sort
    # makes the choice deterministic if that ever stops being true.
    def top_candidate(party)
      candidates.select { |candidate| candidate.party == party.to_s }.min_by(&:id)
    end

    # The strongest non-major-party candidate, used only when a major party has
    # nobody on the ballot. `except` keeps side B from picking side A again.
    def top_minor_candidate(except: nil)
      candidates
        .reject { |candidate| MAJOR_PARTIES.include?(candidate.party) || (except && candidate.name == except) }
        .min_by { |candidate| [ candidate.party == "ind" ? 0 : 1, candidate.id ] }
    end

    def side_for(candidate)
      Side.new(
        party: candidate.party.to_sym,
        caucus: caucus_for(candidate.party, candidate.caucus_with),
        name: candidate.name
      )
    end

    # Party dem/rep caucus with themselves; an independent caucuses where they
    # have said they will, and lands in :uncommitted when they have not.
    def caucus_for(party, caucus_with)
      return party.to_sym if MAJOR_PARTIES.include?(party.to_s)
      return caucus_with.to_sym if caucus_with.present?

      :uncommitted
    end
end
