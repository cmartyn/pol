require "nokogiri"

module Ingest
  # Reads the statewide two-party percentages out of a presidential election
  # article's "Results by state" table and returns each state's D−R margin.
  #
  # The table stacks two header rows — a candidate/party group with colspan 3
  # over Votes / % / EV — so TableGrid's joined column labels come out as
  # "Harris/Walz Democratic %", which is what we look for. Congressional-
  # district rows (ME-1, NE-2) and the totals row are ignored; only the 50
  # statewide rows plus DC are kept.
  class PresidentialResultsParser
    SECTION = /results by state/i
    DEM_PCT = /democratic.*%\z/i
    REP_PCT = /republican.*%\z/i
    STATE_CODES = Race::STATE_NAMES.invert.freeze

    def initialize(html:)
      @html = html
    end

    # => { "AL" => -30.47, "AK" => -13.13, ... } (D minus R, pct pts)
    def call
      table = results_table
      return {} if table.nil?

      grid = TableGrid.build(table)
      labels = grid.column_labels
      dem = labels.index { |label| label.match?(DEM_PCT) }
      rep = labels.index { |label| label.match?(REP_PCT) }
      return {} if dem.nil? || rep.nil?

      grid.body_rows.each_with_object({}) do |cells, margins|
        code = STATE_CODES[state_name(cells.first.text)]
        next if code.nil?

        dem_pct = percentage(cells[dem].text)
        rep_pct = percentage(cells[rep].text)
        next if dem_pct.nil? || rep_pct.nil?

        margins[code] = (dem_pct - rep_pct).round(2)
      end
    end

    private
      def results_table
        Nokogiri::HTML5(@html).css("table.wikitable").find do |table|
          heading = table.ancestors("section").first&.at_css("h1,h2,h3,h4")&.text
          next false unless heading&.match?(SECTION)

          labels = TableGrid.build(table).column_labels
          labels.any? { |label| label.match?(DEM_PCT) } && labels.any? { |label| label.match?(REP_PCT) }
        end
      end

      # Maine's and Nebraska's statewide rows are flagged "Maine †" because
      # they also have per-district rows further down; the dagger is not part of
      # the state's name.
      def state_name(text)
        text.to_s.gsub(/[†‡*]/, "").gsub(/\s+/, " ").strip
      end

      def percentage(text)
        match = /\A([\d.]+)\s*%\z/.match(text.to_s.strip)
        match && match[1].to_f
      end
  end
end
