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
  class PollTableParser
    Row = Struct.new(
      :pollster, :sponsor, :field_start, :field_end, :sample_size, :population,
      :results, :source_url, :raw_payload,
      keyword_init: true
    )

    # A parsed row's per-party number. `candidate` is set only when the column
    # named a candidate we hold.
    Entry = Struct.new(:party, :pct, :candidate, :column, keyword_init: true)

    Result = Struct.new(:rows, :skipped, :reasons, keyword_init: true) do
      def fetched
        rows.size + skipped
      end
    end

    POLLSTER_HEADER = /poll(ster)?\s*source|\Apollster\b/i
    DATE_HEADER = /date/i
    SAMPLE_HEADER = /sample/i
    SPONSOR_HEADER = /sponsor|client/i
    AGGREGATOR_HEADER = /aggregat|dates?\s*updated/i
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

    def initialize(html:, page_url:, candidates: [])
      @html = html
      @page_url = page_url
      @candidates = candidates
    end

    def call
      rows = []
      skipped = 0
      reasons = Hash.new(0)

      document.css("table.wikitable").each do |table|
        grid = TableGrid.build(table)
        layout = layout_for(grid)
        next if layout.nil?

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

      Result.new(rows: rows, skipped: skipped, reasons: reasons)
    end

    private
      def document
        @document ||= Nokogiri::HTML5(@html)
      end

      Layout = Struct.new(:pollster, :date, :sample, :sponsor, :parties, :labels, keyword_init: true)

      # Decides whether a table is a general-election poll table and, if so,
      # which column is which. Returns nil for every other table.
      def layout_for(grid)
        labels = grid.column_labels
        return nil if labels.empty?
        return nil if labels.any? { |label| label.match?(AGGREGATOR_HEADER) }

        pollster = labels.index { |label| label.match?(POLLSTER_HEADER) }
        date = labels.index { |label| label.match?(DATE_HEADER) }
        return nil if pollster.nil? || date.nil?

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

        return nil if parties.size < 2 || parties.values.uniq.size < 2

        matched = match_candidates(parties, labels)
        return nil if matched.nil?

        Layout.new(pollster: pollster, date: date, sample: sample, sponsor: sponsor, parties: matched, labels: labels)
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
      def match_candidates(parties, labels)
        by_party = @candidates.group_by { |candidate| candidate.party.to_sym }

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
          raw_payload: raw_payload(cells, layout, index)
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

      # "Ben Ray Luján" => "lujan"; "Cindy Hyde-Smith" => "hyde-smith".
      def self.surname(name)
        cleaned = name.to_s.gsub(/\s*\([^)]*\)\s*/, " ").gsub(/["'“”‘’]/, "").strip
        last = cleaned.split(/\s+/).last.to_s
        last.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
      end
  end
end
