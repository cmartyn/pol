# TIGERweb responses built from made-up rectangles, so Ingest::BoundarySync
# runs against the API's real response shapes without a real boundary in the
# repository. Each state is a box; its districts are equal vertical strips of
# that box, one per district code.
#
#   stub_tigerweb({
#     "DE" => { fips: "10", box: [ -75.8, 38.4, -75.0, 39.8 ], districts: %w[00] },
#     "RI" => { fips: "44", box: [ -71.9, 41.1, -71.1, 42.0 ], districts: %w[01 02] }
#   })
module TigerwebStubHelper
  STATE_LAYER_ID = 7
  DISTRICT_LAYER_ID = 0

  def stub_tigerweb(states, district_layer: "120th Congressional Districts", district_field: "CD120")
    state_url = Ingest::TigerwebClient.service_url(Ingest::BoundarySync::STATE_SERVICE)
    district_url = Ingest::TigerwebClient.service_url(Ingest::BoundarySync::DISTRICT_SERVICE)

    stub_request(:get, "#{state_url}?f=json").to_return(tigerweb_json(
      "layers" => [
        { "id" => 0, "name" => "Labels", "type" => "Group Layer", "parentLayerId" => -1 },
        { "id" => 2, "name" => Ingest::BoundarySync::STATE_LAYER, "type" => "Feature Layer", "parentLayerId" => 0 },
        { "id" => 3, "name" => "States 5M", "type" => "Feature Layer", "parentLayerId" => -1 },
        { "id" => STATE_LAYER_ID, "name" => Ingest::BoundarySync::STATE_LAYER, "type" => "Feature Layer", "parentLayerId" => -1 }
      ]
    ))
    stub_request(:get, "#{district_url}?f=json").to_return(tigerweb_json(
      "layers" => [ { "id" => 4, "name" => "119th Congressional Districts" }, { "id" => DISTRICT_LAYER_ID, "name" => district_layer } ]
    ))

    state_query = %r{\A#{Regexp.escape(state_url)}/#{STATE_LAYER_ID}/query}
    district_query = %r{\A#{Regexp.escape(district_url)}/#{DISTRICT_LAYER_ID}/query}

    stub_request(:get, state_query).with(query: hash_including("where" => "1=1"))
      .to_return(tigerweb_json(tigerweb_collection(states.map { |postal, spec| tigerweb_state(postal, spec) })))

    states.each do |postal, spec|
      where = { "where" => "STATE='#{spec.fetch(:fips)}'" }
      stub_request(:get, state_query).with(query: hash_including(where))
        .to_return(tigerweb_json(tigerweb_collection([ tigerweb_state(postal, spec) ])))
      stub_request(:get, district_query).with(query: hash_including(where))
        .to_return(tigerweb_json(tigerweb_collection(tigerweb_districts(spec, district_field))))
    end
  end

  def tigerweb_rectangle(west, south, east, north)
    { "type" => "Polygon", "coordinates" => [ [ [ west, south ], [ east, south ], [ east, north ], [ west, north ], [ west, south ] ] ] }
  end

  private
    def tigerweb_state(postal, spec)
      { "type" => "Feature", "properties" => { "STATE" => spec.fetch(:fips), "STUSAB" => postal }, "geometry" => tigerweb_rectangle(*spec.fetch(:box)) }
    end

    def tigerweb_districts(spec, field)
      west, south, east, north = spec.fetch(:box)
      codes = spec.fetch(:districts)
      step = (east - west) / codes.size
      codes.each_with_index.map do |code, index|
        {
          "type" => "Feature",
          "properties" => { "STATE" => spec.fetch(:fips), field => code },
          "geometry" => tigerweb_rectangle(west + (step * index), south, west + (step * (index + 1)), north)
        }
      end
    end

    def tigerweb_collection(features)
      { "type" => "FeatureCollection", "features" => features }
    end

    def tigerweb_json(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end
end
