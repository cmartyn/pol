require "test_helper"

class Ingest::TableGridTest < ActiveSupport::TestCase
  def grid_for(html)
    Ingest::TableGrid.build(Nokogiri::HTML5("<table>#{html}</table>").at_css("table"))
  end

  test "expands rowspan down the column" do
    grid = grid_for(<<~HTML)
      <tr><th>Pollster</th><th>n</th></tr>
      <tr><td rowspan="2">YouGov</td><td>1,472</td></tr>
      <tr><td>1,607</td></tr>
    HTML

    assert_equal [ "YouGov", "1,472" ], grid.rows[1].map(&:text)
    assert_equal [ "YouGov", "1,607" ], grid.rows[2].map(&:text)
  end

  test "expands colspan across the row" do
    grid = grid_for(<<~HTML)
      <tr><th rowspan="2">State</th><th colspan="2">Republican</th></tr>
      <tr><th>Votes</th><th>%</th></tr>
      <tr><td>Alabama</td><td>1,462,616</td><td>64.57%</td></tr>
    HTML

    assert_equal [ "State", "Republican", "Republican" ], grid.rows[0].map(&:text)
    assert_equal [ "State", "Votes", "%" ], grid.rows[1].map(&:text)
  end

  test "joins stacked headers into one label per column" do
    grid = grid_for(<<~HTML)
      <tr><th rowspan="2">State</th><th colspan="2">Harris/Walz Democratic</th></tr>
      <tr><th>Votes</th><th>%</th></tr>
      <tr><td>Alabama</td><td>772,412</td><td>34.10%</td></tr>
    HTML

    assert_equal [ "State", "Harris/Walz Democratic Votes", "Harris/Walz Democratic %" ], grid.column_labels
    assert_equal 2, grid.header_rows.size
    assert_equal 1, grid.body_rows.size
  end

  test "a header row padded out by a wider body row is still a header row" do
    grid = grid_for(<<~HTML)
      <tr><th>Poll source</th><th>Democratic</th></tr>
      <tr><td>Quantus</td><td>49%</td><td>stray</td></tr>
    HTML

    assert_equal 1, grid.header_rows.size
    assert_equal [ "Poll source", "Democratic", "" ], grid.column_labels
  end

  test "cell text drops footnote superscripts and injected styles, and turns <br> into a space" do
    grid = grid_for(<<~HTML)
      <tr><th>Jon<br/>Husted (R)<sup class="reference">[100]</sup></th></tr>
      <tr><td><style>.plainlist{color:red}</style>Sherrod Brown</td></tr>
    HTML

    assert_equal "Jon Husted (R)", grid.rows[0][0].text
    assert_equal "Sherrod Brown", grid.rows[1][0].text
  end

  test "ignores the rows of a table nested inside a cell" do
    grid = grid_for(<<~HTML)
      <tr><th>Outer</th></tr>
      <tr><td><table><tr><td>Inner</td></tr></table></td></tr>
    HTML

    assert_equal 2, grid.rows.size
  end

  test "clamps a rowspan that overruns the end of the table" do
    grid = grid_for(<<~HTML)
      <tr><th>Pollster</th></tr>
      <tr><td rowspan="9">Overreaching</td></tr>
    HTML

    assert_equal 2, grid.rows.size
  end

  test "marks only the origin of a spanned cell as its master" do
    grid = grid_for(<<~HTML)
      <tr><th>a</th></tr>
      <tr><td rowspan="2">spans</td></tr>
      <tr></tr>
    HTML

    assert grid.rows[1][0].master
    assert_not grid.rows[2][0].master
  end
end
