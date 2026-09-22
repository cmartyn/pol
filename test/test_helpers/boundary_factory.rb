# Rectangle boundaries for map tests. Made-up geometry, never a real shape:
# no boundary data lives in this repository, fixtures included.
module BoundaryFactory
  def create_boundary(state:, box:, district: nil)
    west, south, east, north = box
    Boundary.create!(
      state: state,
      district: district,
      source_url: "https://example.com/tigerweb-fixture",
      geometry: { "type" => "Polygon", "coordinates" => [ [ [ west, south ], [ east, south ], [ east, north ], [ west, north ], [ west, south ] ] ] }
    )
  end
end
