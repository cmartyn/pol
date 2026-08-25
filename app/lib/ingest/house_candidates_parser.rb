require "nokogiri"

module Ingest
  # Reads the general-election field out of a state's House page — "2026 United
  # States House of Representatives elections in Michigan" and its forty-nine
  # siblings.
  #
  #   parser = Ingest::HouseCandidatesParser.new(html: html, page_url: url)
  #   parser.call      # => { 1 => [ { "name" => "Jared Golden",
  #                                    "party" => "dem",
  #                                    "incumbent" => true }, ... ], ... }
  #   parser.warnings  # => [ "…district 11: two dem candidates…", ... ]
  #
  # The entries are the shape Ingest::CandidateSync.apply consumes, keyed by
  # district number. Nothing is written here; this is HTML in, hashes out.
  #
  # == What it reads, and why that and not something else
  #
  # Every district section on these pages opens with the same election infobox,
  # and it is the only structure that states the general-election field in one
  # shape all fifty states share:
  #
  #     Nominee   Jack Bergman     Callie Barr
  #     Party     Republican       Democratic
  #     Incumbent U.S. Representative Jack Bergman Republican
  #
  # A survey of eight state pages (92 districts: MI, MN, CA, WA, MA, AK, ND,
  # DE) found the box present on every single district, with only three row
  # labels between them — Nominee, Candidate and Party. The obvious
  # alternatives do not hold up. The "General election > Results" table, which
  # editors pre-fill with the ballot line-up, is richer — it lists minor-party
  # candidates the infobox leaves out — but Minnesota's page does not carry one
  # for any of its eight districts, so a parser built on it would silently drop
  # whole states. The per-party "Nominee" headings under each primary section
  # are a list of that party's pick, not of the field, and Delaware files a
  # nominee under one while the other party's primary has not happened.
  #
  # The infobox names only the leading candidates — usually the two major-party
  # nominees, and in Alaska's ranked-choice field the top two of four. Minor
  # candidates it omits are not recovered; they carry no two-party margin and
  # PollTableParser matches a column with no seeded candidate on party alone.
  #
  # == Settled, unsettled, and the silence in between
  #
  # A district is emitted only when the box names an actual field:
  #
  #   * "TBD" — the primary has not happened, or has not been called.
  #   * "Lori Trahan (presumptive)" — a nominee in waiting, not a nominee.
  #   * one name and an empty column — indistinguishable from a box an editor
  #     has half filled in, so it is not read as an uncontested race. The
  #     genuine uncontested race says so: Florida's 10th reads "Maxwell
  #     Frost(Uncontested)", and that one is emitted as a field of one.
  #
  # None of those produce a warning. Before its primary a state's whole page
  # looks like this, and a daily sweep of fifty states would report four
  # hundred non-events. Unsettled districts are simply absent, which is exactly
  # what Ingest::SyncHouseCandidatesJob wants: a district it does not hear
  # about is left alone rather than emptied.
  #
  # Warnings are for the things that are not routine — a same-party general, a
  # party label we cannot read, an infobox whose rows do not line up.
  class HouseCandidatesParser
    # The label on the row that names the field. Ranked-choice and top-two
    # states head it "Candidate", because a field that never held a party
    # primary has no nominees; everywhere else it is "Nominee".
    FIELD_ROW = /\A(?:Nominee|Candidate)\z/i
    PARTY_ROW = /\AParty\z/i

    # "District 7", and the ordinal form some pages use in its place. Both are
    # PollTableParser's, so a district numbered one way by the poll parser is
    # numbered the same way here.
    DISTRICT_HEADING = /\bdistrict\s+(\d+)\b/i
    ORDINAL_DISTRICT_HEADING = /\b(\d+)(?:st|nd|rd|th)\s+(?:congressional\s+)?district\b/i

    # A state with one at-large district has no "District N" heading anywhere,
    # because there is only the one district to mean, and its infobox sits in
    # the page's lead. Numbering it 1 is the convention Ingest::SeedRaces
    # inherits from HouseResultsParser, which reads "Alaska at-large" as
    # district 1; Ingest::Scraper passes the same number down as
    # default_district.
    AT_LARGE_DISTRICT = 1

    # Markers inside a nominee cell. The first two say the field is not settled
    # yet; the third says it is settled and has one candidate in it. Any other
    # parenthetical is something we have not seen, and guessing whether it
    # means "not yet" or "already" is the guess this parser exists to avoid.
    UNSETTLED_NOMINEE = /\bTBD\b|\bto be determined\b|\(\s*presumptive\s*\)/i
    UNCONTESTED_NOMINEE = /\(\s*uncontested\s*\)/i
    QUALIFIED_NOMINEE = /\(/

    # Party labels, as the infoboxes actually write them. Across those 92
    # districts there were six: Democratic, Republican, "Democratic (DFL)",
    # "Democratic–NPL", Independent and "No party preference". Anchoring at the
    # start of the label is what lets one Democratic pattern cover Minnesota's
    # DFL and North Dakota's NPL without either needing a rule of its own —
    # and the bare "DFL" alternative is there because the 2024 results page
    # does write it that way, at a cost of eight fabricated district baselines
    # the one time it was missed.
    PARTIES = {
      "dem" => /\A(?:democratic|democrat|DFL)\b/i,
      "rep" => /\A(?:republican|GOP)\b/i,
      "ind" => /\A(?:independent|nonpartisan|non-partisan|no party preference|unaffiliated)\b/i,
      # The three third parties organised in enough states to reach a top-two
      # slot. Anything else is reported rather than filed under "other",
      # because the label we have never seen is likelier to be a Democratic
      # variant we failed to learn than a genuine minor party — and a Democrat
      # read as "other" is a race whose polls stop matching a candidate.
      "other" => /\A(?:libertarian|green|constitution)\b/i
    }.freeze

    # A general election has one Democrat and one Republican. Two of either is
    # a top-two or jungle field — California, Washington and Louisiana all run
    # one — and there is no two-party matchup in it to seed.
    MAJOR_PARTIES = %w[dem rep].freeze

    # The line that names the sitting member. Most boxes head it "Incumbent
    # U.S. Representative"; a district whose result is already in swaps that
    # for "U.S. Representative before election" and adds an "Elected U.S.
    # Representative" line beside it, which is a different fact and is not
    # read here.
    INCUMBENT_LINE = /\A(?:incumbent\b|u\.?s\.?\s+representative\s+before\s+election\b)/i

    attr_reader :warnings

    def initialize(html:, page_url:)
      @html = html
      @page_url = page_url
      @warnings = []
    end

    def call
      @warnings = []

      boxes_by_district.each_with_object({}) do |(number, (box, table)), districts|
        entries = field(number, box, table)
        districts[number] = entries if entries
      end
    end

    private
      def document
        @document ||= Nokogiri::HTML5(@html)
      end

      # District number => [infobox, its field table], with a district we
      # cannot place, or that two boxes claim, dropped. Two boxes for one
      # number happens when a page carries a special election for a seat
      # alongside its regular one; which of the two a "District 18" heading
      # meant is not something to guess at when the answer decides whose name
      # goes on a race.
      def boxes_by_district
        boxes = {}

        infoboxes.each do |box, table|
          number = district_for(box)
          if number.nil?
            warn(nil, "#{caption_of(box).inspect}: under no district heading; skipped")
            next
          end

          if boxes.key?(number)
            warn(number, "a second candidate infobox on the page; district skipped")
            boxes[number] = nil
          else
            boxes[number] = [ box, table ]
          end
        end

        boxes.compact
      end

      # Every election infobox on the page, paired with the innermost table
      # that carries its field row. The box nests a table inside a cell of
      # itself, so the rows that matter belong to the inner one — TableGrid
      # reads a table's own rows and would see none of them from outside.
      def infoboxes
        document.css("table.infobox").filter_map do |box|
          table = field_table(box)
          [ box, table ] if table
        end
      end

      def field_table(box)
        tables = ([ box ] + box.css("table").to_a).select do |table|
          table.css("th").any? { |th| th.text.strip.match?(FIELD_ROW) }
        end

        tables.max_by { |table| table.ancestors.size }
      end

      # Nearest enclosing section first, the same order PollTableParser reads
      # headings in, so a box inside "District 7" resolves to 7 whatever is
      # printed above it on the page.
      def district_for(box)
        box.ancestors("section").each do |section|
          heading = section.at_css("h1,h2,h3,h4,h5")&.text.to_s.strip
          next if heading.blank?

          number = heading[DISTRICT_HEADING, 1] || heading[ORDINAL_DISTRICT_HEADING, 1]
          return number.to_i if number
        end

        at_large_page? ? AT_LARGE_DISTRICT : nil
      end

      # A page with no district heading anywhere is a single-seat state. The
      # test is over the whole page rather than over one box: on a fifty-
      # district page a box that sits under no district heading is a box we
      # cannot place, and reading it as district 1 would put one district's
      # candidates on another district's race.
      def at_large_page?
        return @at_large_page if defined?(@at_large_page)

        @at_large_page = document.css("h1,h2,h3,h4,h5").none? do |heading|
          heading.text.match?(DISTRICT_HEADING) || heading.text.match?(ORDINAL_DISTRICT_HEADING)
        end
      end

      # The field for one district: entries, or nil for "say nothing about this
      # district". nil rather than [] deliberately — an empty list handed to
      # CandidateSync means "this race has no candidates" and would delete the
      # ones it has.
      def field(number, box, table)
        grid = TableGrid.build(table)
        names = row_of(grid, FIELD_ROW)
        parties = row_of(grid, PARTY_ROW)
        # The field row is why the box was picked up at all, so a nil here
        # means its label is not where a label goes — a shape we do not read.
        return refuse(number, "infobox's field row is not a row we can read; district skipped") if names.nil?
        return refuse(number, "infobox has no party row; district skipped") if parties.nil?

        nominees = nominees_in(number, names)
        return nil if nominees.blank?
        return refuse(number, "party row is short of the nominees, so which party is whose " \
                              "cannot be told; district skipped") if unaligned?(nominees, parties)

        entries = entries_for(number, nominees, parties, incumbent_line(box))
        return nil if entries.empty?

        duplicated = duplicate_major_party(entries)
        return entries if duplicated.nil?

        named = entries.select { |entry| entry["party"] == duplicated }.map { |entry| entry["name"].inspect }
        refuse(number, "two #{duplicated} candidates in the general (#{named.join(', ')}); district skipped")
      end

      # A row's TableGrid cells by grid column, label included, so that the
      # field row and the party row can be read off the same column index. The
      # cells are kept rather than reduced to their text because two things
      # only they can say are load-bearing here: a cell with no node is one
      # TableGrid padded in because the row was short (see #unaligned?), and
      # Cell#blank? counts a dash placeholder as empty where String#blank?
      # would hand back a candidate named "—".
      def row_of(grid, label)
        grid.rows.find { |cells| cells.first.text.match?(label) }
      end

      # A party row short of the field row is not a party row we can use.
      # TableGrid pads the shortfall, and padding at the end is all a missing
      # cell leaves behind wherever it went missing from: a party row that lost
      # its first cell reads exactly like one that lost its last, with every
      # remaining party sitting a column to the left of the nominee it belongs
      # to. Which of the two happened decides whose name goes on a race, so the
      # district is refused rather than guessed at. Only columns a nominee
      # actually stands in matter — the trailing empty cell these boxes carry
      # on the field row and not on the party row is the ordinary shape.
      def unaligned?(nominees, parties)
        nominees.any? { |_name, column| parties[column].node.nil? }
      end

      # [[name, column], ...] for a settled field, or nil for one that is not
      # settled (silently) or that we cannot read (with a warning).
      def nominees_in(number, names)
        found = []
        uncontested = false

        names.each_with_index do |cell, column|
          next if column.zero? || cell.blank?

          text = cell.text
          return nil if text.match?(UNSETTLED_NOMINEE)

          if text.match?(UNCONTESTED_NOMINEE)
            uncontested = true
            text = text.sub(UNCONTESTED_NOMINEE, "").strip
          elsif text.match?(QUALIFIED_NOMINEE)
            return refuse(number, "nominee #{text.inspect} carries a qualifier we do not read; district skipped")
          end

          found << [ text, column ]
        end

        # One name and nothing opposite it is a box half filled in as often as
        # it is a race nobody contested, and the two are not worth telling
        # apart by guessing: the real uncontested race says so in the cell.
        found if uncontested || found.size > 1
      end

      def entries_for(number, nominees, parties, incumbent)
        nominees.filter_map do |name, column|
          # The cell is there — #unaligned? has already refused the district if
          # it was not — so an empty or unrecognised label is this candidate's
          # problem and not the district's: they are dropped and the rest of
          # the field stands.
          label = parties[column].text
          party = party_for(label)
          if party.nil?
            warn(number, "unreadable party #{label.inspect} for #{name.inspect}; candidate skipped")
            next
          end

          { "name" => name, "party" => party, "incumbent" => incumbent?(incumbent, name) }
        end
      end

      # Every pattern is anchored at the start of the label, so an empty label
      # falls through them all and is reported the same way an unrecognised one
      # is. Neither is guessed at.
      def party_for(label)
        PARTIES.find { |_party, pattern| label.match?(pattern) }&.first
      end

      def duplicate_major_party(entries)
        entries.map { |entry| entry["party"] }.tally
               .find { |party, count| MAJOR_PARTIES.include?(party) && count > 1 }&.first
      end

      # The infobox cells that name the sitting member, joined. There may be
      # two of them — the cell itself and the cell of the box it nests in —
      # which costs nothing, and on a page whose result is in there is a
      # neighbouring "Elected" cell that INCUMBENT_LINE deliberately does not
      # match.
      def incumbent_line(box)
        cells = box.css("th, td").select { |cell| TableGrid.cell_text(cell).match?(INCUMBENT_LINE) }

        normalize(cells.map { |cell| TableGrid.cell_text(cell) }.join(" "))
      end

      # Whether the incumbent line names this candidate. Compared on the whole
      # name rather than a surname, because a challenger who shares a surname
      # with the sitting member is rarer than a district where the same person
      # is both — and compared with the accents stripped, because Florida's
      # 26th runs "Mario Díaz-Balart" against an incumbent line spelled "Mario
      # Diaz-Balart", and its 27th does the same to María Elvira Salazar.
      def incumbent?(line, name)
        return false if line.blank?

        wanted = normalize(name)
        wanted.present? && line.match?(/(?<!#{NAME_CHARACTER})#{Regexp.escape(wanted)}(?!#{NAME_CHARACTER})/)
      end

      # What may not sit against either end of a matched name. The hyphen and
      # the apostrophe are in it so that a challenger called "Mario Diaz" does
      # not match an incumbent line naming "Mario Diaz-Balart".
      NAME_CHARACTER = /[\p{L}'’-]/

      def normalize(text)
        text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.gsub(/\s+/, " ").strip
      end

      def caption_of(box)
        box.at_css("caption")&.text&.strip.presence || "an election infobox"
      end

      # Returns nil so a caller can `return refuse(...)` and read as what it
      # does: say why, and emit nothing for this district.
      def refuse(number, message)
        warn(number, message)
        nil
      end

      def warn(number, message)
        @warnings << [ @page_url, ("district #{number}:" if number), message ].compact.join(" ")
      end
  end
end
