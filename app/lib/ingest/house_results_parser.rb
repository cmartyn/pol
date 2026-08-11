require "nokogiri"

module Ingest
  # Reads every district's 2024 result off
  # "2024 United States House of Representatives elections", whose per-state
  # tables carry a Candidates cell like
  #
  #   ▌Y Barry Moore (Republican) 78.5% ▌Tom Holmes (Democratic) 21.5%
  #
  # Percentages are summed *by party* before subtracting, which is what makes
  # Louisiana's jungle primary (three Republicans on one line) and Alaska's
  # ranked-choice first round come out right.
  class HouseResultsParser
    District = Struct.new(:state, :number, :dem_pct, :rep_pct, :source_url, keyword_init: true) do
      def slug
        "house-2026-#{state.downcase}-#{number.to_s.rjust(2, '0')}"
      end

      # Contested by both major parties, so the margin is real rather than
      # something we have to impute.
      def contested?
        dem_pct.positive? && rep_pct.positive?
      end

      def margin
        dem_pct - rep_pct
      end

      # The party that actually won the district, used to sign an imputed
      # baseline. nil when neither major party appeared at all.
      def leader
        return :dem if dem_pct > rep_pct
        return :rep if rep_pct > dem_pct

        nil
      end
    end

    STATE_CODES = Race::STATE_NAMES.invert.freeze
    EXCLUDED_SECTIONS = [ "Special elections", "Non-voting delegates" ].freeze
    # The district column's header spans two rows ("District" over "Location"),
    # so the joined label reads "District Location".
    DISTRICT_HEADER = /\bdistrict\b/i
    CANDIDATES_HEADER = /candidate/i
    # "Kim Schrier (Democratic) 53.9%" — name, party in parens, percentage.
    CANDIDATE_RESULT = /\(([A-Za-z][A-Za-z .'’–-]*)\)\s*([\d.]+)\s*%/
    # Minnesota's Democrats appear on the ballot as the Democratic–Farmer–Labor
    # party and are labelled "DFL", with no "Democrat" anywhere in the string.
    # Miss that and all eight Minnesota districts read as having no Democratic
    # candidate at all, which turns a +50 seat into an imputed −35 one. (North
    # Dakota's "Democratic-NPL" is caught by the plain pattern already; those
    # two are the only non-standard Democratic labels on the page, out of 28
    # party labels in total — the rest are genuine third parties.)
    DEM = /democrat|\bDFL\b/i
    REP = /republican/i

    def initialize(html:, page_url:)
      @html = html
      @page_url = page_url
    end

    # => { "AL-1" => District, ... }
    def call
      districts = {}

      Nokogiri::HTML5(@html).css("table.wikitable").each do |table|
        state = state_for(table)
        next if state.nil?

        grid = TableGrid.build(table)
        labels = grid.column_labels
        district_column = labels.index { |label| label.match?(DISTRICT_HEADER) }
        candidates_column = labels.index { |label| label.match?(CANDIDATES_HEADER) }
        next if district_column.nil? || candidates_column.nil?

        grid.body_rows.each do |cells|
          district = build_district(state, cells[district_column].text, cells[candidates_column].text)
          next if district.nil?

          districts["#{district.state}-#{district.number}"] ||= district
        end
      end

      districts
    end

    private
      def state_for(table)
        heading = table.ancestors("section").first&.at_css("h1,h2,h3,h4")&.text&.strip
        return nil if heading.blank? || EXCLUDED_SECTIONS.include?(heading)

        STATE_CODES[heading]
      end

      # "Alabama 1" => 1, "Alaska at-large" => 1.
      def build_district(state, district_text, candidates_text)
        number =
          if district_text.match?(/at[-\s]?large/i)
            1
          else
            district_text[/(\d+)\s*\z/, 1]&.to_i
          end
        return nil if number.nil? || number.zero?

        dem = 0.0
        rep = 0.0
        final_round(candidates_text).scan(CANDIDATE_RESULT) do |party, pct|
          dem += pct.to_f if party.match?(DEM)
          rep += pct.to_f if party.match?(REP)
        end

        District.new(state: state, number: number, dem_pct: dem.round(2), rep_pct: rep.round(2), source_url: @page_url)
      end

      # Alaska and Maine use ranked-choice voting, and their cells list every
      # round in one blob ("First round: ... Instant runoff: ..."). Summing the
      # whole thing would count those voters twice, so where rounds are spelled
      # out we keep the last one — the round that decided the seat.
      LATER_ROUND = /(?:instant[- ]runoff|final round|final count|runoff|round \d+)\s*:/i

      def final_round(text)
        text.split(LATER_ROUND).last.to_s.presence || text
      end
  end
end
