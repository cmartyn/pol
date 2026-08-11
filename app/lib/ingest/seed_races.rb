module Ingest
  # Builds the whole race board: the 35 Senate contests from the verified list
  # in db/seed_data/senate_2026.yml, all 435 House districts with their 2024
  # baselines scraped from Wikipedia, and each Senate race's presidential lean.
  #
  # Idempotent: every race is upserted by slug, so re-running after a primary
  # resolves updates in place rather than duplicating.
  class SeedRaces
    # Raised rather than seeding a partial House. Wikipedia can restructure a
    # page at any time, and a parser that quietly returns 300 districts would
    # leave the forecast silently wrong instead of visibly broken.
    IncompleteSource = Class.new(StandardError)

    SENATE_DATA = Rails.root.join("db/seed_data/senate_2026.yml")
    HOUSE_DISTRICTS = 435

    Summary = Struct.new(:senate, :specials, :house, :imputed, :imputed_districts, :leans, :warnings, keyword_init: true)

    # expected_districts is the floor the House parse has to clear. Tests that
    # run against the trimmed fixture pass the subset they expect; nil skips
    # the check entirely.
    def initialize(client: WikipediaClient.new, logger: Rails.logger, expected_districts: HOUSE_DISTRICTS)
      @client = client
      @logger = logger
      @expected_districts = expected_districts
      @warnings = []
    end

    def call
      senate = seed_senate
      leans = seed_leans(senate)
      house, imputed = seed_house

      Summary.new(
        senate: senate.size,
        specials: senate.count(&:special?),
        house: house,
        imputed: imputed.size,
        imputed_districts: imputed,
        leans: leans,
        warnings: @warnings
      )
    end

    private
      def cycle
        @cycle ||= Sources.cycle
      end

      def seed_senate
        YAML.safe_load_file(SENATE_DATA).map do |entry|
          special = entry.fetch("special", false)
          race = Race.find_or_initialize_by(slug: senate_slug(entry["state"], special))
          race.assign_attributes(
            office: :senate,
            cycle: cycle,
            state: entry.fetch("state"),
            special: special,
            seat_class: entry["seat_class"],
            incumbent_name: entry["incumbent_name"],
            incumbent_party: entry["incumbent_party"],
            open_seat: entry.fetch("open_seat", false)
          )
          race.save!
          sync_candidates(race, entry.fetch("candidates", []))
          race
        end
      end

      def senate_slug(state, special)
        "senate-#{cycle}-#{state.downcase}#{'-special' if special}"
      end

      def sync_candidates(race, entries)
        entries.each do |entry|
          candidate = race.candidates.find_or_initialize_by(name: entry.fetch("name"))
          candidate.update!(
            party: entry.fetch("party"),
            caucus_with: entry["caucus_with"],
            incumbent: entry.fetch("incumbent", false)
          )
        end

        prune_candidates(race, entries.map { |entry| entry.fetch("name") })
      end

      # A candidate who has dropped off the verified list is removed so that the
      # poll parser's "column must name a real candidate" rule keeps rejecting
      # stale matchups — unless polls already point at them, in which case the
      # historical link is worth more than the tidiness.
      def prune_candidates(race, names)
        race.candidates.where.not(name: names).find_each do |stale|
          if PollResult.exists?(candidate_id: stale.id)
            @warnings << "kept #{race.slug} candidate #{stale.name.inspect}: referenced by existing poll results"
          else
            stale.destroy!
          end
        end
      end

      # lean = mean over 2024 and 2020 of (state margin − national margin),
      # D−R percentage points.
      def seed_leans(races)
        nationals = {
          2024 => Pol::Params.fetch!(:fundamentals, :pres_national_margin_2024),
          2020 => Pol::Params.fetch!(:fundamentals, :pres_national_margin_2020)
        }
        margins = Sources::PRESIDENTIAL_TITLES.transform_values do |title|
          PresidentialResultsParser.new(html: @client.page_html(title)).call
        end

        races.count do |race|
          relative = margins.filter_map { |year, by_state| by_state[race.state] && by_state[race.state] - nationals[year] }
          if relative.size < margins.size
            @warnings << "no presidential lean for #{race.slug}: state missing from #{margins.size - relative.size} results table(s)"
            next false
          end

          race.update!(lean: (relative.sum / relative.size).round(2))
          true
        end
      end

      def seed_house
        title = Sources::HOUSE_RESULTS_TITLE
        districts = HouseResultsParser.new(html: @client.page_html(title), page_url: WikipediaClient.article_url(title)).call
        check_district_count!(districts, title)

        default = Pol::Params.fetch!(:fundamentals, :imputed_baseline_margin).to_f
        imputed = []

        districts.each_value do |district|
          margin, is_imputed = baseline_for(district, default)
          imputed << "#{district.state}-#{district.number}" if is_imputed

          race = Race.find_or_initialize_by(slug: district.slug)
          race.assign_attributes(
            office: :house,
            cycle: cycle,
            state: district.state,
            district: district.number,
            baseline_margin: margin,
            baseline_source_url: district.source_url,
            baseline_imputed: is_imputed
          )
          race.save!
        end

        [ districts.size, imputed ]
      end

      # Raised before a single House row is written, so a page we can no longer
      # read fully fails the task rather than half-filling the board. Senate
      # seeding has already run at this point, but it is idempotent — fix the
      # parser and re-run.
      def check_district_count!(districts, title)
        return if @expected_districts.nil? || districts.size == @expected_districts

        found = districts.keys.group_by { |key| key.split("-").first }.transform_values(&:size)
        raise IncompleteSource,
              "#{title} parsed #{districts.size} districts, expected #{@expected_districts}. " \
              "Refusing to seed a partial House. Districts found per state: #{found.sort.to_h.inspect}"
      end

      # Districts where a major party did not appear on the 2024 ballot (safe
      # seats, and California/Washington top-two races that ended D-vs-D) get
      # the documented imputed margin, signed toward whoever actually won.
      def baseline_for(district, default)
        return [ district.margin.round(2), false ] if district.contested?

        case district.leader
        when :dem then [ default, true ]
        when :rep then [ -default, true ]
        else
          @warnings << "#{district.state}-#{district.number}: neither major party polled a vote in 2024; baseline set to 0"
          [ 0.0, true ]
        end
      end
  end
end
