module Newsroom
  # The payload a dispatch is written from — built ONLY from our own tables.
  #
  # This is the other half of the data-grounding rule (the first half being the
  # system prompt's "you have no other information"): if a fact is not in here,
  # the model has no legitimate way to put it in the piece, and any number it
  # prints can be traced back to a row. It also carries `citable_poll_ids`,
  # which is the exact set Newsroom::Validation checks citations against.
  #
  # Everything is pre-formatted the way the site formats it — whole-percent
  # probabilities, "D+3.2" margins — via Site::Format, so a dispatch and the
  # race page it links to cannot disagree about what the same number is called.
  class Context
    PARTY_NAMES = { "dem" => "Democrat", "rep" => "Republican", "ind" => "independent", "other" => "other" }.freeze
    # How a headline an editor pulled is presented to the writer. The prompt's
    # "WHAT WE HAVE ALREADY SAID" section keys off this exact string.
    RETRACTED_MARKER = "[RETRACTED by editor]".freeze
    POPULATIONS = {
      "lv" => "likely voters", "rv" => "registered voters", "a" => "adults", "unknown" => "unspecified"
    }.freeze

    class << self
      # The polls that just landed for one race, plus where the forecast stood
      # before and after them.
      def poll_reaction(race:, polls:, model_run:)
        new(kind: :poll_reaction, race: race, model_run: model_run).build(
          new_polls: polls,
          previous_run: ModelRun.previous_succeeded(model_run)
        )
      end

      # One race that moved between two runs, with any polling that arrived in
      # between as the possible explanation.
      def movement_note(race:, model_run:, previous_run:)
        polls = polls_since(race, previous_run)
        new(kind: :movement_note, race: race, model_run: model_run).build(
          new_polls: polls, previous_run: previous_run, movement: true
        )
      end

      # The national picture: both chambers, the environment, the movers, and
      # the most recent polling anywhere on the board.
      def daily_brief(model_run:)
        new(kind: :daily_brief, race: nil, model_run: model_run).build(
          new_polls: recent_polls, movers: Site::Movers.call
        )
      end

      private
        def polls_since(race, previous_run)
          return Poll.none unless previous_run&.started_at

          race.polls.where(created_at: previous_run.started_at..).includes(:pollster, poll_results: :candidate)
        end

        def recent_polls
          Poll.recent_first
              .limit(Pol::Params.fetch!(:newsroom, :brief_poll_count))
              .includes(:race, :pollster, poll_results: :candidate)
        end
    end

    def initialize(kind:, race:, model_run:, today: Date.current)
      @kind = kind
      @race = race
      @model_run = model_run
      @today = today
    end

    attr_reader :kind, :race, :model_run, :today

    def build(new_polls: [], previous_run: nil, movement: false, movers: nil)
      polls = Array(new_polls)

      {
        kind: kind.to_s,
        today: long_date(today),
        election_date: long_date(election_date),
        days_to_election: (election_date - today).to_i,
        national: national,
        race: race && race_section(previous_run),
        movement: movement ? movement_section(previous_run) : nil,
        polls: polls.map { |poll| poll_section(poll) }.presence,
        movers: movers && movers.map { |mover| mover_section(mover) },
        recent_headlines: recent_headlines.presence,
        citable_poll_ids: polls.map(&:id)
      }.compact
    end

    private
      def election_date
        @election_date ||= Date.parse(Pol::Params.fetch!(:election, :date))
      end

      def national
        senate = chamber_forecast(:senate)
        house = chamber_forecast(:house)

        {
          numbers_as_of: run_time(model_run),
          generic_ballot: generic_ballot,
          senate: senate && chamber_section(senate).merge(seats_needed_for_control),
          house: house && chamber_section(house).merge(
            seats_needed: Pol::Params.fetch!(:chambers, :house_majority_seats),
            must_say: Prompts::HOUSE_CAVEAT
          )
        }.compact
      end

      # The thresholds the simulator counted against, in the payload because a
      # model without them reaches for its own. The first live brief written
      # from this context said Democrats were "short of the 50 needed" in the
      # Senate — 50 is the Republicans' number, not theirs, because the vice
      # president is a Republican. Derived here exactly as
      # Forecast::Simulator#senate_outcome derives them.
      def seats_needed_for_control
        vp_party = Pol::Params.fetch!(:chambers, :vp_party)
        tie = Pol::Params.fetch!(:chambers, :senate_total_seats) / 2

        {
          dem_seats_needed: vp_party == "dem" ? tie : tie + 1,
          rep_seats_needed: vp_party == "rep" ? tie : tie + 1,
          tiebreak: "the vice president is a #{PARTY_NAMES.fetch(vp_party)}, so a #{tie}-#{tie} tie " \
                    "goes to the #{PARTY_NAMES.fetch(vp_party)}s"
        }
      end

      def generic_ballot
        average = Forecast::Averager.new(as_of: today).for_generic_ballot
        return { average: nil, note: "no generic-ballot polls in the window" } unless average.polled?

        {
          average: Site::Format.margin(average.mean_margin, side_a_party: "dem", side_b_party: "rep"),
          polls_in_average: average.poll_count,
          window_days: average.window_days
        }
      end

      def chamber_forecast(chamber)
        return nil unless model_run

        @chamber_forecasts ||= model_run.chamber_forecasts.index_by(&:chamber)
        @chamber_forecasts[chamber.to_s]
      end

      def chamber_section(forecast)
        {
          dem_control: Site::Format.percent(forecast.p_dem_control),
          rep_control: Site::Format.percent(forecast.p_rep_control),
          dem_control_in_100: Site::Format.x_in_100(forecast.p_dem_control),
          mean_dem_seats: forecast.mean_dem_seats.round(1)
        }
      end

      def race_section(previous_run)
        candidates = race.candidates.to_a

        {
          name: race.name,
          office: race.office,
          state: Race::STATE_NAMES.fetch(race.state, race.state),
          district: race.district,
          special: race.special,
          open_seat: race.open_seat,
          incumbent: race.incumbent_name.presence && {
            name: race.incumbent_name, party: PARTY_NAMES[race.incumbent_party]
          },
          candidates: candidates.map { |candidate| candidate_section(candidate) },
          forecast: forecast_section(forecast_for(model_run), candidates),
          previous_forecast: previous_run && forecast_section(forecast_for(previous_run), candidates)
            &.merge(from_run_at: run_time(previous_run))
        }.compact
      end

      def candidate_section(candidate)
        {
          name: candidate.name,
          party: PARTY_NAMES[candidate.party],
          incumbent: candidate.incumbent
        }.compact
      end

      def forecast_for(run)
        return nil unless run && race

        Forecast.find_by(model_run_id: run.id, race_id: race.id)
      end

      def forecast_section(forecast, candidates)
        return nil unless forecast

        side_a, side_b = Site::RaceSides.for(candidates)

        {
          dem_win: Site::Format.percent(forecast.p_dem_win),
          rep_win: Site::Format.percent(forecast.p_rep_win),
          dem_win_in_100: Site::Format.x_in_100(forecast.p_dem_win),
          other_win: (Site::Format.percent(forecast.p_other_win) if forecast.p_other_win > 0.005),
          mean_margin: Site::Format.margin(forecast.mean_margin, side_a_party: side_a, side_b_party: side_b),
          range_5_95: percentile_range(forecast, side_a, side_b)
        }.compact
      end

      def percentile_range(forecast, side_a, side_b)
        percentiles = forecast.margin_percentiles
        return nil if percentiles.blank?

        interval = Site::Format.percentile_interval(percentiles, side_a_party: side_a, side_b_party: side_b)
        "#{interval[:label]} percentile: #{interval[:low]} to #{interval[:high]}"
      rescue KeyError
        nil
      end

      # The movement note's whole subject: how far this race's probability
      # travelled, over what span. Stated in points of win probability, the
      # same unit the movers module on the dashboard uses.
      def movement_section(previous_run)
        latest = forecast_for(model_run)
        previous = forecast_for(previous_run)
        return nil unless latest && previous

        delta_pp = (latest.p_dem_win - previous.p_dem_win) * 100.0

        {
          change: format("%+.1f points of Democratic win probability", delta_pp),
          toward: delta_pp.positive? ? "the Democrat" : "the Republican",
          from: Site::Format.percent(previous.p_dem_win),
          to: Site::Format.percent(latest.p_dem_win),
          since: run_time(previous_run),
          days_between: ((model_run.started_at - previous_run.started_at) / 1.day).round
        }
      end

      def poll_section(poll)
        {
          id: poll.id,
          race: poll.generic_ballot? ? "generic congressional ballot" : poll.race&.name,
          pollster: poll.pollster.name,
          sponsor: poll.sponsor.presence,
          fielded: fielded(poll),
          field_end: poll.field_end.to_s,
          sample_size: poll.sample_size,
          population: POPULATIONS[poll.population],
          source: source_domain(poll.source_url),
          results: poll.poll_results.map do |result|
            { candidate: result.candidate&.name, party: PARTY_NAMES[result.party], pct: result.pct }.compact
          end
        }.compact
      end

      def mover_section(mover)
        {
          race: mover.race.name,
          change: format("%+.1f points of Democratic win probability", mover.delta_pp),
          from: Site::Format.percent(mover.previous_p_dem_win),
          to: Site::Format.percent(mover.latest_p_dem_win)
        }
      end

      # What the newsroom has already said, so it doesn't say it again. Race
      # pieces see that race's recent headlines; the national brief sees the
      # whole feed's.
      #
      # Retracted pieces are in this list, flagged. A headline a human pulled is
      # the single most important one not to write again, and scoping this to
      # published rows had the opposite effect: retraction erased the piece from
      # the newsroom's memory, leaving the writer free to re-assert exactly what
      # an editor had just taken down. The prompt tells it to treat a flagged
      # entry as withdrawn rather than as a story to follow up.
      def recent_headlines
        scope = Dispatch.recent_first.limit(Pol::Params.fetch!(:newsroom, :recent_headline_count))
        scope = scope.where(race_id: race.id) if race

        scope.map do |dispatch|
          entry = {
            headline: dispatch.retracted? ? "#{RETRACTED_MARKER} #{dispatch.headline}" : dispatch.headline,
            kind: dispatch.kind,
            published: dispatch.published_at && long_date(dispatch.published_at.to_date)
          }.compact
          dispatch.retracted? ? entry.merge(retracted: true) : entry
        end
      end

      def fielded(poll)
        start_date = poll.field_start
        end_date = poll.field_end
        return long_date(end_date) if start_date.blank? || start_date == end_date

        if start_date.year == end_date.year && start_date.month == end_date.month
          "#{start_date.strftime('%B %-d')}-#{end_date.strftime('%-d, %Y')}"
        else
          "#{long_date(start_date)} to #{long_date(end_date)}"
        end
      end

      # "November 3, 2026". Not Rails' :long date format, which pads the day.
      def long_date(date)
        date.strftime("%B %-d, %Y")
      end

      def source_domain(url)
        URI.parse(url.to_s).host
      rescue URI::InvalidURIError
        nil
      end

      def run_time(run)
        return nil unless run

        (run.finished_at || run.started_at)&.in_time_zone(Newsroom::ZONE)&.strftime("%B %-d, %Y at %-l:%M %p ET")
      end
  end
end
