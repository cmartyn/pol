require "nokogiri"

module Ingest
  # Pulls poll rows out of the wikitables on a Wikipedia election page.
  #
  #   Ingest::PollTableParser.new(
  #     html: html, page_url: url, candidates: race.candidates.to_a
  #   ).call
  #
  # A "Polling" section on one of these pages mixes three kinds of table, and
  # only one of them is a general-election poll:
  #
  #   * aggregator averages   — headed "Source of poll aggregation"; skipped.
  #   * primary polls         — columns are bare candidate names with no party
  #                             marker, so no party columns are found; skipped.
  #   * general-election polls— columns carry party markers, e.g.
  #                             "Jon Ossoff (D)" / "Mike Collins (R)", or the
  #                             generic ballot's plain "Democratic"/"Republican".
  #
  # Among the third kind, a page also carries hypothetical matchups against
  # people who did not end up as nominees. When the race has candidates seeded
  # for a party, a column of that party must name one of them, which leaves
  # exactly the real matchup. Races with no seeded candidate for a party (the
  # ones whose primary has not happened yet) fall back to matching on party
  # alone.
  #
  # Every table the parser declines is counted and given a reason, so that
  # "this page has no polling" and "we could not read this page's polling" stop
  # being the same answer. Reasons are per-table; `no_polling_section`
  # describes a page that had no polling table to decline in the first place.
  #
  # A state's House page (scope: :district) is the same tables under a
  # different roof: each one sits inside a "District 7" section, and that
  # enclosing section — not the row, and not the nearest heading above it in
  # reading order — is what says which race a table belongs to.
  class PollTableParser
    Row = Struct.new(
      :pollster, :sponsor, :field_start, :field_end, :sample_size, :population,
      :results, :source_url, :raw_payload, :district, :matchup_key,
      keyword_init: true
    )

    # A parsed row's per-party number. `candidate` is set only when the column
    # named a candidate we hold.
    Entry = Struct.new(:party, :pct, :candidate, :column, keyword_init: true)

    # `skipped`/`reasons` count rows dropped out of a table we did read;
    # `refused`/`refusals` count whole tables we declined. The two are
    # deliberately separate: three unreadable rows in a good table and three
    # refused tables are different kinds of trouble.
    Result = Struct.new(:rows, :skipped, :reasons, :refused, :refusals, keyword_init: true) do
      def fetched
        rows.size + skipped
      end
    end

    # Every reason the parser can give for declining a table. Each is something
    # the code genuinely distinguishes — there is no catch-all.
    REFUSAL_REASONS = %i[
      no_polling_section
      aggregator_table
      results_table
      primary_only_table
      generic_candidate_column
      multiple_same_party_columns
      no_party_columns
      no_candidate_column_match
      layout_unrecognized
      district_unresolved
    ].freeze

    POLLSTER_HEADER = /poll(ster)?\s*source|\Apollster\b/i
    DATE_HEADER = /date/i
    SAMPLE_HEADER = /sample/i
    SPONSOR_HEADER = /sponsor|client/i
    AGGREGATOR_HEADER = /aggregat|dates?\s*updated/i
    # A count of ballots, not of opinions. California's 22nd files its primary
    # result table inside the Polling section, so this has to be told apart
    # from a poll table we failed to read rather than lumped in with it.
    RESULTS_HEADER = /\Avotes\b/i
    # Columns that look like they might be results but are not a party's number.
    NON_PARTY_HEADER = /\A(other|undecided|others|none|margin|lead|spread|net|total|sample|date|poll|source|sponsor|client|mode|notes?)\b|\bof error\b|other\s*\/\s*undecided/i
    PCT = /\A(\d{1,3}(?:\.\d+)?)\s*%?\z/

    TAGGED_PARTY = {
      dem: /\(\s*(?:D|Dem|Democrat|Democratic|DFL)\s*\)/i,
      rep: /\(\s*(?:R|GOP|Rep|Republican)\s*\)/i,
      ind: /\(\s*(?:I|Ind|Independent)\s*\)/i,
      other: /\(\s*(?:L|Lib|Libertarian|G|Green|C|Constitution|WF|Working\s+Families)\s*\)/i
    }.freeze

    # Parties whose column a pollster may reasonably have left out of a given
    # poll. A missing Democrat or Republican means the row is not a matchup.
    MINOR_PARTIES = %i[ind other].freeze

    BARE_PARTY = {
      dem: /\b(?:Democratic|Democrat|DFL)\b/i,
      rep: /\b(?:Republican|GOP)\b/i,
      ind: /\bIndependent\b/i
    }.freeze

    # A party tag written after a pollster's name marks its partisan sponsor,
    # not part of its identity: "Tulchin Research (D)" and "Tulchin Research"
    # have to canonicalise to the same pollster.
    POLLSTER_PARTY_TAG = /\s*\(\s*(?:D|R|I|D-aligned|R-aligned)\s*\)/i

    # A heading that puts a table in scope: everything under it is polling, so
    # a table we decline there is a refusal worth counting. A wikitable
    # anywhere else (endorsements, fundraising, results by county) is simply
    # not a poll table and is passed over in silence.
    POLLING_HEADING = /\bpoll/i
    PRIMARY_HEADING = /\bprimar(?:y|ies)\b/i
    GENERAL_HEADING = /\bgeneral election\b/i
    DISTRICT_HEADING = /\bdistrict\s+(\d+)\b/i
    ORDINAL_DISTRICT_HEADING = /\b(\d+)(?:st|nd|rd|th)\s+(?:congressional\s+)?district\b/i
    AT_LARGE_HEADING = /\bat[-\s]?large\b/i

    # "Generic Democrat", "Generic Republican", "Another Democratic candidate":
    # a placeholder where a name belongs. The number is real but it is not a
    # matchup between two people, and treating it as one would put a poll of
    # nobody into a district's average. (The nationwide generic ballot is a
    # different thing and says so — its columns read "Democratic" and
    # "Republican", with no placeholder word.)
    GENERIC_CANDIDATE = /\bgeneric\b|\banother\b/i

    # A general election has one Democrat and one Republican. Two columns
    # tagged with the same major party mean a field, not a matchup — a top-two
    # or jungle primary, which Washington, California and Louisiana all run and
    # all label with party tags that would otherwise sail through.
    MAJOR_PARTIES = %i[dem rep].freeze

    # scope: :page     — one race per page (a Senate race, or the generic
    #                    ballot), candidates given as a flat list.
    # scope: :district — a state's House page, many races on it. Candidates
    #                    arrive keyed by district number, and default_district
    #                    is set only for a state that has a single at-large
    #                    district, where the page carries no "District N"
    #                    heading because there is only one.
    def initialize(html:, page_url:, candidates: [], scope: :page, district_candidates: {}, default_district: nil)
      @html = html
      @page_url = page_url
      @candidates = candidates
      @scope = scope
      @district_candidates = district_candidates
      @default_district = default_district
    end

    def call
      rows = []
      skipped = 0
      reasons = Hash.new(0)
      refusals = Hash.new(0)

      tables = polling_tables
      refusals[:no_polling_section] += 1 if tables.empty?

      tables.each do |table, grid, headings|
        layout = layout_for(grid, headings)
        if layout.is_a?(Symbol)
          refusals[layout] += 1
          next
        end

        anchor = section_anchor(table)
        grid.body_rows.each_with_index do |cells, index|
          row = build_row(cells, layout, anchor, index)
          if row.is_a?(Row)
            rows << row
          elsif row
            skipped += 1
            reasons[row] += 1
          end
        end
      end

      # `refused` counts tables. A page with no polling section refused none —
      # there was nothing there to turn down — so the reason is recorded and
      # the count stays at zero.
      Result.new(rows: rows, skipped: skipped, reasons: reasons,
                 refused: refusals.except(:no_polling_section).values.sum, refusals: refusals)
    end

    private
      def document
        @document ||= Nokogiri::HTML5(@html)
      end

      Layout = Struct.new(:pollster, :date, :sample, :sponsor, :parties, :labels, :district, keyword_init: true)

      # The tables a refusal can be counted against: everything under a Polling
      # heading, plus anything that carries a poll table's own header shape
      # wherever it sits (a page whose sectioning we cannot see must not become
      # a page with no polls).
      def polling_tables
        document.css("table.wikitable").filter_map do |table|
          grid = TableGrid.build(table)
          headings = section_headings(table)
          next unless headings.any? { |heading| heading.match?(POLLING_HEADING) } || poll_shaped?(grid)

          [ table, grid, headings ]
        end
      end

      def poll_shaped?(grid)
        labels = grid.column_labels
        labels.any? { |label| label.match?(POLLSTER_HEADER) } && labels.any? { |label| label.match?(DATE_HEADER) }
      end

      # Nearest enclosing section first, which is what makes "District 7 >
      # General election > Polling" resolve to district 7 and not to whatever
      # district happens to be printed above it on the page.
      def section_headings(table)
        table.ancestors("section").filter_map { |section| section.at_css("h1,h2,h3,h4,h5")&.text&.strip.presence }
      end

      # Decides whether a table is a general-election poll table and, if so,
      # which column is which. Returns a refusal reason for every other table.
      def layout_for(grid, headings)
        labels = grid.column_labels
        return :layout_unrecognized if labels.empty?
        return :aggregator_table if labels.any? { |label| label.match?(AGGREGATOR_HEADER) }
        return :results_table if labels.any? { |label| label.match?(RESULTS_HEADER) }

        pollster = labels.index { |label| label.match?(POLLSTER_HEADER) }
        date = labels.index { |label| label.match?(DATE_HEADER) }
        return :layout_unrecognized if pollster.nil? || date.nil?
        return :primary_only_table if primary_section?(headings)

        district = nil
        if @scope == :district
          district = district_for(headings)
          return :district_unresolved if district.nil?
        end

        taken = [ pollster, date ].compact
        sample = labels.index { |label| label.match?(SAMPLE_HEADER) }
        sponsor = labels.index { |label| label.match?(SPONSOR_HEADER) }
        taken += [ sample, sponsor ].compact

        parties = {}
        labels.each_with_index do |label, index|
          next if taken.include?(index)

          party = party_for(label)
          parties[index] = party if party
        end

        return :generic_candidate_column if parties.each_key.any? { |index| labels[index].match?(GENERIC_CANDIDATE) }
        return :no_party_columns if parties.size < 2
        # Before the one-party test, not after it: California's 11th is a real
        # top-two general between two Democrats, and it has party columns —
        # calling that "no party-labelled columns" reads like a parser failure
        # when it is an accurate description of the ballot. Refusing is still
        # right, because there is no two-party margin in it to measure.
        return :multiple_same_party_columns if duplicate_major_party?(parties)
        return :no_party_columns if parties.values.uniq.size < 2

        matched = match_candidates(parties, labels, candidates_for(district))
        return :no_candidate_column_match if matched.nil?

        Layout.new(pollster: pollster, date: date, sample: sample, sponsor: sponsor,
                   parties: matched, labels: labels, district: district)
      end

      # A table under a primary heading is a primary field even when its
      # columns carry party tags, which is exactly the case a structural test
      # alone would wave through in the top-two states.
      def primary_section?(headings)
        headings.any? { |heading| heading.match?(PRIMARY_HEADING) } &&
          headings.none? { |heading| heading.match?(GENERAL_HEADING) }
      end

      # An at-large heading says "the whole state", which is a district number
      # only the caller knows — the same one it passes as default_district for
      # a state with a single seat. Reading it as 1 here would be the one
      # district number the parser invented rather than read.
      def district_for(headings)
        headings.each do |heading|
          return @default_district if heading.match?(AT_LARGE_HEADING)

          number = heading[DISTRICT_HEADING, 1] || heading[ORDINAL_DISTRICT_HEADING, 1]
          return number.to_i if number
        end

        @default_district
      end

      def candidates_for(district)
        return @candidates if @scope != :district

        @district_candidates[district] || []
      end

      def duplicate_major_party?(parties)
        parties.values.tally.any? { |party, count| MAJOR_PARTIES.include?(party) && count > 1 }
      end

      def party_for(label)
        return nil if label.blank? || label.match?(NON_PARTY_HEADER)

        TAGGED_PARTY.each { |party, pattern| return party if label.match?(pattern) }
        return nil if label.include?("(")

        BARE_PARTY.each { |party, pattern| return party if label.match?(pattern) }
        nil
      end

      # For each party column: if we hold candidates of that party, the column
      # has to name one of them (that is what rejects hypothetical matchups);
      # otherwise the column stands on its party alone. Returns nil to reject
      # the whole table.
      def match_candidates(parties, labels, candidates)
        by_party = candidates.group_by { |candidate| candidate.party.to_sym }

        parties.each_with_object({}) do |(index, party), matched|
          pool = by_party[party]
          if pool.blank?
            matched[index] = [ party, nil ]
            next
          end

          surname = self.class.surname(strip_party_tag(labels[index]))
          candidate = pool.find { |c| self.class.surname(c.name) == surname }
          return nil if candidate.nil?

          matched[index] = [ party, candidate ]
        end
      end

      def build_row(cells, layout, anchor, index)
        return nil if note_row?(cells)

        pollster = strip_party_tag(cells[layout.pollster].text)
        return :missing_pollster if pollster.blank? || pollster.match?(/\A[-–—]\z/)

        dates = DateRange.parse(cells[layout.date].text)
        return :unparseable_dates if dates.nil?

        results = []
        layout.parties.each do |column, (party, candidate)|
          # A dashed minor-party cell means the poll did not test that
          # candidate — routine where a table carries a Libertarian or
          # independent column that only some pollsters included. That is a
          # column with no result, not a zero. A dashed *major*-party column is
          # a different animal: the poll is not a usable matchup, so the row
          # goes.
          next if cells[column].blank? && MINOR_PARTIES.include?(party)

          match = PCT.match(cells[column].text)
          return :missing_percentage if match.nil?

          results << Entry.new(party: party, pct: match[1].to_f, candidate: candidate, column: layout.labels[column])
        end
        return :missing_percentage if results.size < 2 || results.map(&:party).uniq.size < 2

        size, population = SampleSize.parse(layout.sample ? cells[layout.sample].text : "")

        Row.new(
          pollster: pollster,
          sponsor: layout.sponsor ? cells[layout.sponsor].text.presence : nil,
          field_start: dates.first,
          field_end: dates.last,
          sample_size: size,
          population: population,
          results: results,
          source_url: anchor,
          raw_payload: raw_payload(cells, layout, index),
          district: layout.district,
          # Which contest this row measured, not just which race it belongs to.
          # A district's page publishes several while its nominees are
          # unsettled, and averaging across them is averaging across people who
          # cannot all be on the ballot.
          matchup_key: Matchup.key(results.map(&:column))
        )
      end

      # Structural rows rather than polls: blank separator rows, and the
      # "Primary elections are held" dividers, which are one cell stretched
      # across most of the table. A genuine poll row never has a cell spanning
      # half the columns.
      def note_row?(cells)
        nodes = cells.filter_map(&:node)
        return true if nodes.uniq.size <= 1

        nodes.tally.values.max >= cells.size / 2.0
      end

      def raw_payload(cells, layout, index)
        columns = layout.labels.each_with_index.to_h { |label, i| [ label.presence || "column_#{i}", cells[i].text ] }
        { "row_index" => index, "columns" => columns }
      end

      def strip_party_tag(text)
        text.to_s.gsub(POLLSTER_PARTY_TAG, "").gsub(/\s+/, " ").strip
      end

      # The page URL plus the enclosing section's anchor, so a poll's
      # source_url lands the reader on the table it came from.
      def section_anchor(table)
        heading = table.ancestors("section").first&.at_css("h1,h2,h3,h4,h5")
        id = heading && (heading["id"] || heading.at_css("[id]")&.[]("id"))
        id.present? ? "#{@page_url}##{id}" : @page_url
      end

      # A generational suffix is not a surname. Without this, "Nick Begich III"
      # is a person called "iii" and "Mike Bouchard Jr." and "Tom Kean Jr." are
      # the same person — which matters little for matching a column against a
      # candidate we hold (both sides are reduced the same way) and a great
      # deal for telling two matchups apart.
      NAME_SUFFIX = /\A(?:jr|sr|ii|iii|iv|v)\.?\z/i

      # "Ben Ray Luján" => "lujan"; "Cindy Hyde-Smith" => "hyde-smith";
      # "Nick Begich III" => "begich".
      def self.surname(name)
        cleaned = name.to_s.gsub(/\s*\([^)]*\)\s*/, " ").gsub(/["'“”‘’]/, "").strip
        parts = cleaned.split(/\s+/)
        parts.pop while parts.size > 1 && parts.last.match?(NAME_SUFFIX)
        parts.last.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
      end
  end
end
