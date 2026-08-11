require "erb"

# Stubs for the one external service this app talks to. Every test that
# exercises ingestion goes through here, so "did we accidentally hit the
# network" has exactly one answer: no.
module WikipediaStubHelper
  FIXTURES = Rails.root.join("test/fixtures/files")

  # The URL Ingest::WikipediaClient actually requests for a page title.
  def wikipedia_url(title)
    Ingest::WikipediaClient::ENDPOINT + ERB::Util.url_encode(title)
  end

  # stub_wikipedia_page("2026 United States elections", fixture: "generic_ballot.html")
  # stub_wikipedia_page("Some Title", body: "<html>...</html>")
  # stub_wikipedia_page("Missing Page", status: 404)
  def stub_wikipedia_page(title, fixture: nil, body: nil, status: 200)
    body ||= fixture ? FIXTURES.join(fixture).read : ""
    stub_request(:get, wikipedia_url(title))
      .to_return(status: status, body: body, headers: { "Content-Type" => "text/html; charset=utf-8" })
  end

  # A minimal but structurally faithful poll table: same section/heading
  # wrapper, header row and column shape as the real Parsoid HTML, so parser
  # behaviour in these tests is the behaviour on the real thing.
  def poll_page_html(rows:, dem_column: "Jordan Ellis (D)", rep_column: "Pat Rivers (R)", section_id: "Polling")
    body = rows.map do |row|
      cells = [ row[:pollster], row[:dates], row[:sample], "± 3.0%", row[:dem], row[:rep] ]
      "<tr>#{cells.map { |cell| "<td>#{cell}</td>" }.join}</tr>"
    end.join

    <<~HTML
      <html><body><section data-mw-section-id="1">
        <h2 id="#{section_id}">Polling</h2>
        <table class="wikitable">
          <tbody>
            <tr>
              <th>Poll source</th><th>Date(s)<br/>administered</th><th>Sample<br/>size</th>
              <th>Margin<br/>of error</th><th>#{dem_column}</th><th>#{rep_column}</th>
            </tr>
            #{body}
          </tbody>
        </table>
      </section></body></html>
    HTML
  end
end
