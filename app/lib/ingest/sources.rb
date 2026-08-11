module Ingest
  # Which Wikipedia pages we read, and what each race's page is called. Kept in
  # one place so the seeder, the scraper and the fixture-refresh task cannot
  # drift apart.
  module Sources
    # The two historical results pages are fixed by the methodology (2024 House
    # baselines; 2024 + 2020 presidential for state lean), so their titles are
    # constants rather than something derived from the cycle.
    HOUSE_RESULTS_TITLE = "2024 United States House of Representatives elections".freeze
    PRESIDENTIAL_TITLES = {
      2024 => "2024 United States presidential election",
      2020 => "2020 United States presidential election"
    }.freeze

    # Where 2026 House district polling actually lives, established by reading
    # all 50 state pages once (docs/BUILD_NOTES.md Phase 8 §A). There is no
    # consolidated district-polling page — the national article carries only
    # generic-ballot aggregator averages — and no per-district articles exist
    # for 2026, so the state page is the unit.
    #
    # These are the states whose page carried at least one general-election
    # district poll on 2026-08-11. Scraping all 50 every two hours would be
    # ~70 MB a sweep for pages we know are empty; the 33 here are ~46 MB. The
    # list is a snapshot and goes stale in one direction only — a state that
    # gains its first district poll will not be picked up until it is
    # refreshed, which is why the survey method is written down in the build
    # notes alongside the nine states that were closest to qualifying.
    DISTRICT_POLL_STATES = %w[
      AK AL AR AZ CA CO FL IA ID IL IN KY ME MI MN MO MT NC NE NH
      NJ NM NV NY OH PA SC TN TX VA VT WA WI
    ].freeze

    class << self
      # The cycle comes from the one place every constant lives.
      def cycle
        Date.parse(Pol::Params.fetch!(:election, :date)).year
      end

      # "2026 United States Senate election in Georgia"
      # "2026 United States Senate special election in Ohio"
      def senate_title(race)
        state = Race::STATE_NAMES.fetch(race.state)
        "#{race.cycle} United States Senate #{'special ' if race.special?}election in #{state}"
      end

      # Individual generic-ballot polls live here. The obvious alternative,
      # "2026 United States House of Representatives elections", carries only
      # aggregator averages.
      def generic_ballot_title
        "#{cycle} United States elections"
      end

      # "2026 United States House of Representatives elections in Michigan",
      # but "…election in Alaska" for a state with a single at-large district
      # — Wikipedia uses the singular there and the plural title 404s.
      def district_title(state, single_district:)
        name = Race::STATE_NAMES.fetch(state)
        "#{cycle} United States House of Representatives election#{'s' unless single_district} in #{name}"
      end

      # The state pages the sweep will read, in order, capped by
      # scrape.max_district_sources. Returns [kept, dropped] so the caller can
      # say out loud what the cap cost.
      def district_states
        limit = Pol::Params.fetch!(:scrape, :max_district_sources).to_i
        [ DISTRICT_POLL_STATES.first(limit), DISTRICT_POLL_STATES.drop(limit) ]
      end
    end
  end
end
