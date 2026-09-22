# A state's shoreline-clipped outline (district nil) or one congressional
# district, as simplified lon/lat GeoJSON fetched from the Census Bureau by
# Ingest::BoundarySync. Keyed like races — state + district — so a map joins
# the two without a lookup table. Longitudes are stored continuous across the
# date line (see BoundarySync.normalize), so nothing downstream special-cases
# the Aleutians.
class Boundary < ApplicationRecord
  validates :state, presence: true, format: { with: /\A[A-Z]{2}\z/, message: "must be a 2-letter code" }
  validates :geometry, :source_url, presence: true
  validates :district, uniqueness: { scope: :state }

  scope :outlines, -> { where(district: nil) }
  scope :districts, -> { where.not(district: nil) }

  # Every ring — exterior and hole alike — as [lon, lat] pairs. Maps draw
  # them with fill-rule evenodd, so which ring is a hole never matters here.
  def rings
    case geometry["type"]
    when "Polygon" then geometry["coordinates"]
    when "MultiPolygon" then geometry["coordinates"].flatten(1)
    else []
    end
  end
end
