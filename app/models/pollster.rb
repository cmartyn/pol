class Pollster < ApplicationRecord
  # Pollster.canonicalize("Data for Progress") => "data-for-progress"
  #
  # Lowercases the name, collapses every run of non-alphanumeric characters
  # into a single dash, and strips leading/trailing dashes. This is the
  # dedup key ingestion (Phase 2) uses to find-or-create a pollster from a
  # scraped name, so two spellings of the same pollster ("AtlasIntel" vs
  # "Atlas Intel") canonicalize to the same slug.
  def self.canonicalize(name)
    name.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end
end
