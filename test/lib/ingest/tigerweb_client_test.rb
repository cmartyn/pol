require "test_helper"

class Ingest::TigerwebClientTest < ActiveSupport::TestCase
  SERVICE = "TIGERweb/Legislative".freeze
  SERVICE_URL = Ingest::TigerwebClient.service_url(SERVICE)

  setup do
    @client = Ingest::TigerwebClient.new
  end

  def layers(*pairs)
    { status: 200, body: { layers: pairs.map { |id, name| { id: id, name: name } } }.to_json }
  end

  test "finds a layer id by name, because TIGERweb renumbers layers between releases" do
    stub_request(:get, "#{SERVICE_URL}?f=json").to_return(layers([ 4, "119th Congressional Districts" ], [ 0, "120th Congressional Districts" ]))

    assert_equal 0, @client.layer_id(SERVICE, "120th Congressional Districts")
  end

  test "a missing layer name raises LayerNotFound" do
    stub_request(:get, "#{SERVICE_URL}?f=json").to_return(layers([ 0, "120th Congressional Districts" ]))

    assert_raises(Ingest::TigerwebClient::LayerNotFound) { @client.layer_id(SERVICE, "121st Congressional Districts") }
  end

  test "features returns the exact query url and the GeoJSON features" do
    stub = stub_request(:get, %r{\A#{Regexp.escape(SERVICE_URL)}/0/query})
      .with(query: hash_including("where" => "STATE='44'", "outFields" => "STATE,CD120", "outSR" => "4326",
                                  "f" => "geojson", "maxAllowableOffset" => "0.000400"))
      .to_return(status: 200, body: { type: "FeatureCollection", features: [
        { type: "Feature", properties: { "CD120" => "01" }, geometry: tigerweb_rectangle(0, 0, 1, 1) }
      ] }.to_json)

    url, features = @client.features(SERVICE, 0, where: "STATE='44'", out_fields: %w[STATE CD120], max_allowable_offset: 0.0004)

    assert_requested stub
    assert url.start_with?("#{SERVICE_URL}/0/query?")
    assert_equal "01", features.sole.dig("properties", "CD120")
  end

  test "an ArcGIS error object inside a 200 raises FetchFailed with its message" do
    stub_request(:get, %r{/query}).to_return(status: 200, body: { error: { code: 400, message: "Invalid query" } }.to_json)

    error = assert_raises(Ingest::TigerwebClient::FetchFailed) do
      @client.features(SERVICE, 0, where: "nonsense", out_fields: [], max_allowable_offset: 0.1)
    end
    assert_includes error.message, "Invalid query"
  end

  test "a truncated result raises rather than returning part of a state" do
    stub_request(:get, %r{/query}).to_return(status: 200, body: { type: "FeatureCollection", features: [], properties: { exceededTransferLimit: true } }.to_json)

    assert_raises(Ingest::TigerwebClient::FetchFailed) do
      @client.features(SERVICE, 0, where: "1=1", out_fields: [], max_allowable_offset: 0.1)
    end
  end

  test "retries a server error, then succeeds" do
    stub_request(:get, "#{SERVICE_URL}?f=json").to_return({ status: 503, body: "" }, layers([ 7, "States 500K" ]))

    assert_equal 7, @client.layer_id(SERVICE, "States 500K")
  end

  test "gives up after the last attempt" do
    stub_request(:get, "#{SERVICE_URL}?f=json").to_return(status: 503, body: "")

    assert_raises(Ingest::TigerwebClient::FetchFailed) { @client.layer_id(SERVICE, "States 500K") }
    assert_requested :get, "#{SERVICE_URL}?f=json", times: Ingest::TigerwebClient::ATTEMPTS
  end

  test "identifies itself with the contact address" do
    stub = stub_request(:get, "#{SERVICE_URL}?f=json").with(headers: { "User-Agent" => /contact: / }).to_return(layers([ 0, "x" ]))

    @client.layer_id(SERVICE, "x")

    assert_requested stub
  end
end
