module Ingest
  # Flattens an HTML table into a dense rows × columns grid, expanding rowspan
  # and colspan so that grid[r][c] always answers "what is in this cell".
  #
  # Wikipedia's tables need this: a poll source cell routinely spans four
  # result rows, and results-by-state tables stack two header rows with
  # colspans. Every parser in Ingest works on a grid rather than on <tr>s.
  class TableGrid
    # `master` is true only for the cell's own row/column origin, so callers can
    # tell a real cell from the shadow of a span (used to spot note rows, which
    # are a single cell stretched across the whole table).
    Cell = Struct.new(:text, :header, :node, :master, keyword_init: true) do
      def blank?
        text.blank? || text.match?(/\A[-–—*]\z/)
      end
    end

    EMPTY = Cell.new(text: "", header: false, node: nil, master: false).freeze

    attr_reader :rows

    def self.build(table)
      new(table).tap(&:build)
    end

    def initialize(table)
      @table = table
      @rows = []
    end

    def build
      source_rows = own_rows
      grid = []

      source_rows.each_with_index do |tr, r|
        grid[r] ||= []
        column = 0

        cells_in(tr).each do |node|
          column += 1 while grid[r][column]

          rowspan = [ span(node, "rowspan"), source_rows.size - r ].min
          colspan = span(node, "colspan")
          text = self.class.cell_text(node)

          rowspan.times do |dr|
            grid[r + dr] ||= []
            colspan.times do |dc|
              grid[r + dr][column + dc] =
                Cell.new(text: text, header: node.name == "th", node: node, master: dr.zero? && dc.zero?)
            end
          end

          column += colspan
        end
      end

      width = grid.map { |row| row&.size.to_i }.max.to_i
      @rows = grid.map { |row| Array.new(width) { |i| (row && row[i]) || EMPTY } }
      self
    end

    # The leading run of rows made entirely of <th> — one row for a poll table,
    # two for the presidential results-by-state tables. Padding cells (node nil,
    # added where a later row is wider than the header) do not disqualify a row.
    def header_rows
      rows.take_while { |row| row.any?(&:header) && row.all? { |cell| cell.header || cell.node.nil? } }
    end

    def body_rows
      rows.drop(header_rows.size)
    end

    # One label per column, built by joining that column's header cells and
    # dropping repeats (a colspan header contributes the same text to each of
    # its columns, so "Harris/Walz Democratic" + "%" becomes one label).
    def column_labels
      headers = header_rows
      return [] if headers.empty?

      Array.new(rows.first.size) do |c|
        headers.filter_map { |row| row[c].text.presence }.uniq.join(" ").squeeze(" ").strip
      end
    end

    # Visible text of a cell: reference/footnote superscripts and injected
    # <style> blocks removed, <br> turned into a space so "Jon<br>Husted (R)"
    # does not come out as "JonHusted (R)".
    def self.cell_text(node)
      copy = node.dup
      copy.css("style, sup").each(&:remove)
      copy.css("br").each { |br| br.replace(" ") }
      copy.text.tr(" ", " ").gsub(/\s+/, " ").strip
    end

    private
      # Rows belonging to this table, not to a table nested inside one of its
      # cells.
      def own_rows
        @table.css("tr").select { |tr| tr.ancestors("table").first == @table }
      end

      def cells_in(tr)
        tr.element_children.select { |node| node.name == "th" || node.name == "td" }
      end

      def span(node, attribute)
        value = node[attribute].to_i
        value.positive? ? value : 1
      end
  end
end
