module Ingest
  module Nyt
    # One NYT question → the arguments Ingest::RecordPoll takes. All the
    # judgment lives here: which questions are in scope, how the feed's
    # party codes and race labels land on our board, and which questions are
    # declined with a counted reason rather than guessed at.
    #
    # A question is out of scope (skipped, not refused) when the feed is
    # answering a question we deliberately don't ask: a primary, another
    # cycle, a party-subsample read. Refusals are reserved for questions we
    # *should* be able to place and can't — those are the ones a scrape run
    # needs to alarm on.
    class Mapper
      # DEM/REP/IND land on our enum directly; every other code the feed
      # uses (LIB, GRE, PSL, NPA, CON, WCP, ALL, OTH…) is a minor line our
      # model files under :other. NONE is not a party at all — it tags
      # "Don't know" / "Someone else" rows — and is dropped before mapping.
      PARTY_MAP = { "DEM" => :dem, "REP" => :rep, "IND" => :ind }.freeze
      PARTISAN_MAP = { "DEM" => :dem, "REP" => :rep, "IND" => :ind, "OTH" => :oth }.freeze
      PARTY_LETTERS = { dem: "D", rep: "R", ind: "I" }.freeze
      POPULATIONS = %w[lv rv a].freeze

      SENATE = "U.S. Senate".freeze
      HOUSE = "U.S. House".freeze
      GENERIC_STATE = "US".freeze

      # The feed writes month/day/two-digit-year. Matched strictly because
      # Date.strptime's %y quietly reads only the first two digits of a
      # four-digit year — "7/8/2026" would parse as 2020 and ingest a poll
      # six years outside every averaging window. A format change should
      # refuse loudly (and, refusing everything, trip the dark-run alarm),
      # not backdate the corpus.
      US_DATE = %r{\A\d{1,2}/\d{1,2}/\d{2}\z}

      # Every reason #map can refuse with — plus the one Sync adds when
      # RecordPoll declines what the mapper passed. ScrapeRun's label test
      # holds this list and the parser's to the same "every reason has a
      # label" contract.
      REFUSAL_REASONS = %i[
        unknown_race ambiguous_senate_race too_few_parties missing_field_dates
        generic_candidate record_invalid
      ].freeze

      Outcome = Struct.new(:status, :attrs, :results, :reason, keyword_init: true) do
        def mapped? = status == :mapped
        def skipped? = status == :skipped
        def refused? = status == :refused
      end

      def initialize(source:, cycle: Ingest::Sources.cycle)
        @source = source
        @cycle = cycle.to_s
        senate = Race.where(office: :senate).includes(:candidates).group_by(&:state)
        # In 2026 no state carries both a regular and a special Senate race,
        # so state alone resolves. The moment a cycle breaks that, matching
        # by state would silently attach both seats' polls to one race —
        # refusing is the honest reading until the mapper learns seat_name.
        @senate_by_state = senate.select { |_, races| races.size == 1 }.transform_values(&:first)
        @ambiguous_senate_states = senate.select { |_, races| races.size > 1 }.keys.to_set
        @house_by_district = Race.where(office: :house).includes(:candidates)
                                 .index_by { |race| [ race.state, race.district ] }
      end

      def map(question)
        return skipped unless in_scope?(question)

        race, refusal = resolve_race(question)
        return refused(refusal) if refusal

        rows = candidate_rows(question)
        if race && rows.any? { |row| row["candidate_name"].to_s.match?(PollTableParser::GENERIC_CANDIDATE) }
          # The Wikipedia parser refuses placeholder candidates at the door
          # (generic_candidate_column); the feed door holds the same line. A
          # "Generic Democrat vs LePage" question would otherwise mint a
          # phantom matchup key no page could produce. The generic ballot is
          # exempt — its answers are SUPPOSED to be generic, and race is nil
          # there.
          return refused(:generic_candidate)
        end

        field_start, field_end = parse_dates(question)
        return refused(:missing_field_dates) if field_end.nil?

        results_by_party = build_results(rows, race)
        return refused(:too_few_parties) if results_by_party.size < 2

        Outcome.new(
          status: :mapped,
          attrs: attrs_for(question, race, field_start, field_end, results_by_party),
          results: results_by_party.values.map { |r| r.slice(:party, :pct, :candidate) }
        )
      end

      private
        def in_scope?(question)
          question.poll_field("stage") == "general" &&
            question.poll_field("cycle").to_s == @cycle &&
            question.rows.all? { |row| row["subpopulation"].to_s.strip.empty? }
        end

        # [race, refusal_reason] — exactly one is set, except the generic
        # ballot, where both are nil.
        def resolve_race(question)
          office = question.poll_field("office_type")
          state = question.poll_field("state").to_s

          if office == SENATE
            return [ nil, :ambiguous_senate_race ] if @ambiguous_senate_states.include?(state)

            race = @senate_by_state[state]
            [ race, race ? nil : :unknown_race ]
          elsif office == HOUSE && state == GENERIC_STATE
            [ nil, nil ]
          elsif office == HOUSE
            race = @house_by_district[[ state, question.poll_field("seat_number").to_i ]]
            [ race, race ? nil : :unknown_race ]
          else
            [ nil, :unknown_race ]
          end
        end

        # The rows that name a candidate — party=NONE rows ("Don't know",
        # "Someone else") are answers, not candidates. Ranked-choice
        # questions (AK, ME) collapse to one round: the reallocated final
        # when the feed carries it, since a two-way margin is what the model
        # reads, else the first preferences.
        def candidate_rows(question)
          rows = question.rows.reject { |row| row["party"].to_s == "NONE" || row["party"].to_s.strip.empty? }
          rcv = rows.select { |row| row["ranked_choice_round"].to_s.strip.present? }
          return rows if rcv.empty?

          finals = rcv.select { |row| row["ranked_choice_final"].to_s.casecmp?("TRUE") }
          return finals if finals.any?

          first_round = rcv.map { |row| row["ranked_choice_round"].to_f }.min
          rcv.select { |row| row["ranked_choice_round"].to_f == first_round }
        end

        def parse_dates(question)
          [ parse_date(question.poll_field("start_date")), parse_date(question.poll_field("end_date")) ]
        end

        def parse_date(value)
          text = value.to_s.strip
          return nil unless text.match?(US_DATE)

          Date.strptime(text, "%m/%d/%y")
        rescue Date::Error
          nil
        end

        # One result per party, first row wins where a party repeats — the
        # rule the Wikipedia parser applied to a page's columns.
        def build_results(rows, race)
          rows.each_with_object({}) do |row, results|
            party = PARTY_MAP.fetch(row["party"], :other)
            pct = parse_pct(row["pct"])
            next if pct.nil?

            results[party] ||= {
              party: party, pct: pct, name: row["candidate_name"].to_s.strip,
              raw_party: row["party"], candidate: match_candidate(race, party, row["candidate_name"])
            }
          end
        end

        def parse_pct(value)
          pct = Float(value.to_s)
          pct.between?(0, 100) ? pct : nil
        rescue ArgumentError, TypeError
          nil
        end

        def match_candidate(race, party, name)
          return nil unless race

          surname = PollTableParser.surname(name)
          race.candidates.find { |c| c.party == party.to_s && PollTableParser.surname(c.name) == surname }
        end

        def attrs_for(question, race, field_start, field_end, results_by_party)
          {
            pollster_name: question.poll_field("pollster").to_s.strip,
            nyt_pollster_id: question.poll_field("pollster_id"),
            race: race,
            field_start: field_start,
            field_end: field_end,
            sample_size: parse_sample_size(question.poll_field("sample_size")),
            population: parse_population(question.poll_field("population")),
            sponsor: question.poll_field("sponsors").presence,
            partisan: PARTISAN_MAP.fetch(question.poll_field("partisan").to_s, :none),
            methodology: question.poll_field("methodology").presence,
            source_url: question.poll_field("url").presence || Client.url_for(@source),
            matchup_key: matchup_key(race, results_by_party),
            nyt_poll_id: question.poll_field("poll_id"),
            nyt_question_id: question.question_id,
            digest_salt: question.question_id,
            raw_payload: raw_payload(question, results_by_party)
          }
        end

        def parse_sample_size(value)
          size = value.to_s.delete(",").to_i
          size.positive? ? size : nil
        end

        def parse_population(value)
          POPULATIONS.include?(value.to_s) ? value.to_s.to_sym : :unknown
        end

        # Generic-ballot questions name parties, not people, so they carry
        # no matchup — exactly like the Wikipedia generic corpus.
        def matchup_key(race, results_by_party)
          return nil if race.nil?

          pairs = results_by_party.transform_values { |result| result[:name] }
          Ingest::Matchup.key_from_parties(pairs)
        end

        # `columns` reproduces the shape the Wikipedia parser stored —
        # "James Talarico (D)" => "45.0" — so matchup_label, the poll table,
        # and every other reader of a poll's provenance works identically on
        # feed rows. The feed's own identifiers ride alongside under `nyt`.
        def raw_payload(question, results_by_party)
          columns = results_by_party.values.to_h do |result|
            letter = PARTY_LETTERS[result[:party]] || result[:raw_party]
            [ "#{result[:name]} (#{letter})", format("%g", result[:pct]) ]
          end

          {
            "columns" => columns,
            "nyt" => {
              "poll_id" => question.poll_field("poll_id"),
              "question_id" => question.question_id,
              "rows" => question.rows.map { |row| row.compact.reject { |_, v| v.to_s.empty? } }
            }
          }
        end

        def skipped = Outcome.new(status: :skipped)
        def refused(reason) = Outcome.new(status: :refused, reason: reason.to_s)
    end
  end
end
