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
    end
  end
end
