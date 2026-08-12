module Pol
  # The nine U.S. Census divisions, and which state sits in each. The
  # simulator draws one shared error per division per simulated world, so this
  # table decides which races have a bad night together — it is a model input,
  # not a display detail, and it is transcribed from the Census Bureau rather
  # than written from memory.
  #
  # Verified 2026-08-11 against two independent census.gov sources that agree
  # exactly, one prose and one machine-readable:
  #   https://www.census.gov/programs-surveys/economic-census/guidance-geographies/levels.html
  #   https://www2.census.gov/programs-surveys/popest/geographies/2023/state-geocodes-v2023.xlsx
  # (the latter is "Census Bureau Region and Division Codes and Federal
  # Information Processing System (FIPS) Codes for States", released May 2024;
  # its 51 state rows were joined to Race::STATE_NAMES to get the codes below).
  # Both list divisions in this order and states alphabetically within them,
  # which is the order kept here — see Forecast::Simulator, where the order
  # shared draws are taken in is part of what a seed reproduces.
  #
  # Why divisions and not the four Census *regions*: 538's House model puts 2
  # points of correlated error at "the regional level", and a four-region
  # split would make one shared shock cover the entire South (16 states, 150-
  # odd districts). Nine divisions is the finest standard grouping published,
  # which is the conservative reading of "regional" for a term whose job is to
  # correlate neighbours rather than half the country.
  #
  # DC is in the table because the Census puts it in the South Atlantic, and
  # leaving it out would mean this file disagreed with its own source. It never
  # draws: the District has no Senate seat and no voting House district, so no
  # 2026 race carries it (the live board has races in exactly 50 states) and
  # the simulator only draws for states that have a race in doubt. Territories
  # are absent for the same reason the Census omits them here — they are not
  # states — and #for raises on one rather than silently dropping a race out of
  # the correlated structure.
  module CensusDivisions
    NEW_ENGLAND = "New England".freeze
    MIDDLE_ATLANTIC = "Middle Atlantic".freeze
    EAST_NORTH_CENTRAL = "East North Central".freeze
    WEST_NORTH_CENTRAL = "West North Central".freeze
    SOUTH_ATLANTIC = "South Atlantic".freeze
    EAST_SOUTH_CENTRAL = "East South Central".freeze
    WEST_SOUTH_CENTRAL = "West South Central".freeze
    MOUNTAIN = "Mountain".freeze
    PACIFIC = "Pacific".freeze

    STATES_BY_DIVISION = {
      NEW_ENGLAND => %w[CT ME MA NH RI VT],
      MIDDLE_ATLANTIC => %w[NJ NY PA],
      EAST_NORTH_CENTRAL => %w[IL IN MI OH WI],
      WEST_NORTH_CENTRAL => %w[IA KS MN MO NE ND SD],
      SOUTH_ATLANTIC => %w[DE DC FL GA MD NC SC VA WV],
      EAST_SOUTH_CENTRAL => %w[AL KY MS TN],
      WEST_SOUTH_CENTRAL => %w[AR LA OK TX],
      MOUNTAIN => %w[AZ CO ID MT NV NM UT WY],
      PACIFIC => %w[AK CA HI OR WA]
    }.freeze

    DIVISION_BY_STATE = STATES_BY_DIVISION.flat_map { |division, states|
      states.map { |state| [ state, division ] }
    }.to_h.freeze

    module_function

    # Pol::CensusDivisions.for("GA") => "South Atlantic"
    #
    # Raises rather than returning nil: a state with no division would take no
    # regional error at all, which is a race quietly falling out of the
    # correlated structure — the exact failure this phase exists to fix, and
    # one that would show up as a slightly-too-narrow seat distribution rather
    # than as anything anyone would notice.
    def for(state)
      DIVISION_BY_STATE.fetch(state.to_s) do
        raise KeyError, "Pol::CensusDivisions: no census division for state #{state.inspect}"
      end
    end

    # The nine names, in Census order.
    def names
      STATES_BY_DIVISION.keys
    end

    # Every code in the table: the 50 states plus DC.
    def state_codes
      DIVISION_BY_STATE.keys
    end
  end
end
