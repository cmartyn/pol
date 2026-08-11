require "test_helper"

class Ingest::WikipediaClientTest < ActiveSupport::TestCase
  TITLE = "2026 United States elections".freeze

  setup do
    @client = Ingest::WikipediaClient.new(min_interval: 0, backoff_base: 0)
  end

  test "fetches a page and returns its HTML as UTF-8" do
    stub_wikipedia_page(TITLE, body: "<html>Ben Ray Luján</html>")

    html = @client.page_html(TITLE)

    assert_equal "<html>Ben Ray Luján</html>", html
    assert_equal Encoding::UTF_8, html.encoding
  end

  test "identifies itself with the contact address from model_params" do
    contact = Pol::Params.fetch!(:scrape, :user_agent_contact)
    stub_wikipedia_page(TITLE, body: "ok")

    @client.page_html(TITLE)

    assert_requested :get, wikipedia_url(TITLE), headers: {
      "User-Agent" => "pol/0.1 (2026 midterms forecast site; contact: #{contact})"
    }
  end

  test "url-encodes the title, spaces included" do
    stub_wikipedia_page("2026 United States Senate election in Rhode Island", body: "ok")

    @client.page_html("2026 United States Senate election in Rhode Island")

    assert_requested :get, "#{Ingest::WikipediaClient::ENDPOINT}2026%20United%20States%20Senate%20election%20in%20Rhode%20Island"
  end

  test "follows the same-host redirect the REST endpoint answers with" do
    stub_request(:get, wikipedia_url(TITLE))
      .to_return(status: 301, headers: { "Location" => "/w/rest.php/v1/page/2026_United_States_elections/html" })
    stub_request(:get, "https://en.wikipedia.org/w/rest.php/v1/page/2026_United_States_elections/html")
      .to_return(status: 200, body: "redirected body")

    assert_equal "redirected body", @client.page_html(TITLE)
  end

  test "refuses to follow a redirect off en.wikipedia.org" do
    stub_request(:get, wikipedia_url(TITLE))
      .to_return(status: 302, headers: { "Location" => "https://evil.example.com/page" })

    error = assert_raises(Ingest::WikipediaClient::FetchFailed) { @client.page_html(TITLE) }

    assert_match(/off-host/, error.message)
    assert_not_requested :get, "https://evil.example.com/page"
  end

  test "gives up after a redirect loop rather than spinning" do
    stub_request(:get, wikipedia_url(TITLE)).to_return(status: 301, headers: { "Location" => wikipedia_url(TITLE) })

    assert_raises(Ingest::WikipediaClient::FetchFailed) { @client.page_html(TITLE) }
  end

  test "raises NotFound on 404 without retrying" do
    stub_wikipedia_page(TITLE, status: 404)

    assert_raises(Ingest::WikipediaClient::NotFound) { @client.page_html(TITLE) }

    assert_requested :get, wikipedia_url(TITLE), times: 1
  end

  test "retries a 5xx up to three attempts, then fails" do
    stub_wikipedia_page(TITLE, status: 503)

    assert_raises(Ingest::WikipediaClient::FetchFailed) { @client.page_html(TITLE) }

    assert_requested :get, wikipedia_url(TITLE), times: Ingest::WikipediaClient::ATTEMPTS
  end

  test "retries a timeout and returns the eventual success" do
    stub_request(:get, wikipedia_url(TITLE)).to_timeout.then.to_return(status: 200, body: "second time lucky")

    assert_equal "second time lucky", @client.page_html(TITLE)
    assert_requested :get, wikipedia_url(TITLE), times: 2
  end

  test "backs off for longer on each retry" do
    slept = []
    client = Ingest::WikipediaClient.new(min_interval: 0, backoff_base: 0.5, sleeper: ->(seconds) { slept << seconds })
    stub_wikipedia_page(TITLE, status: 500)

    assert_raises(Ingest::WikipediaClient::FetchFailed) { client.page_html(TITLE) }

    assert_equal [ 0.5, 1.0 ], slept
  end

  test "paces itself to one request per interval" do
    slept = []
    client = Ingest::WikipediaClient.new(min_interval: 1.0, backoff_base: 0, sleeper: ->(seconds) { slept << seconds })
    stub_wikipedia_page(TITLE, body: "ok")

    client.page_html(TITLE)
    assert_empty slept, "the first request should not wait"

    client.page_html(TITLE)
    assert_equal 1, slept.size
    assert_operator slept.first, :<=, 1.0
    assert_operator slept.first, :>, 0
  end

  test "article_url points at the human-readable page" do
    assert_equal "https://en.wikipedia.org/wiki/2026_United_States_elections",
                 Ingest::WikipediaClient.article_url("2026 United States elections")
  end
end
