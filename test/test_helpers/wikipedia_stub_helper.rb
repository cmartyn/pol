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

  # Every state House page a sweep will reach for, stubbed as a page with
  # nothing on it. A test that is not about district polls still has to answer
  # for them, and this is how it says "not my subject" — mirroring exactly how
  # Ingest::Scraper picks its district sources so the two cannot drift.
  def stub_district_pages(body: "<html><body><section><h2>Candidates</h2></section></body></html>")
    scraped, = Ingest::Sources.district_states

    Race.house.where(cycle: Ingest::Sources.cycle).group_by(&:state).each do |state, races|
      next unless scraped.include?(state)

      stub_wikipedia_page(Ingest::Sources.district_title(state, single_district: races.one?), body: body)
    end
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

  # One election infobox per district — structurally faithful to the field
  # Ingest::HouseCandidatesParser reads: a Nominee row, a Party row, and (if
  # given) an Incumbent line naming the sitting member as one cell, the way a
  # real infobox joins "Incumbent U.S. Representative" and the name into a
  # single <td> rather than a labelled row of its own.
  #
  # districts: [ { number:, nominees: [ [name, party_label], ... ], incumbent: name_or_nil }, ... ]
  # at_large: true omits every "District N" heading — HouseCandidatesParser
  # reads "no such heading anywhere on the page" as a single at-large seat.
  def house_candidates_page_html(districts:, at_large: false)
    sections = districts.map do |district|
      names = district.fetch(:nominees).map(&:first)
      parties = district.fetch(:nominees).map(&:last)
      incumbent_cell = district[:incumbent] ? "Incumbent U.S. Representative #{district[:incumbent]}" : ""
      heading = at_large ? "" : "<h2>District #{district.fetch(:number)}</h2>"

      <<~HTML
        <section>#{heading}
          <table class="infobox">
            <tbody>
              <tr><td>#{incumbent_cell}</td></tr>
              <tr><th>Nominee</th>#{names.map { |name| "<td>#{name}</td>" }.join}</tr>
              <tr><th>Party</th>#{parties.map { |party| "<td>#{party}</td>" }.join}</tr>
            </tbody>
          </table>
        </section>
      HTML
    end

    "<html><body>#{sections.join}</body></html>"
  end
end
