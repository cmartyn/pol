class Pollster < ApplicationRecord
  has_many :polls, dependent: :restrict_with_error

  scope :excluded, -> { where.not(excluded_at: nil) }

  normalizes :exclusion_reason, :exclusion_source_url, with: ->(value) { value&.strip.presence }
  validates :exclusion_reason, presence: true, if: :excluded?
  validates :exclusion_reason, length: { maximum: 1000 }
  validates :exclusion_source_url, length: { maximum: 2000 },
            format: { with: /\Ahttps?:\/\/[^\s]+\z/, message: "must be an http or https URL" }, allow_blank: true

  before_validation :clear_exclusion_details, unless: :excluded?
  after_save_commit :refresh_forecast, if: :saved_change_to_excluded_at?

  def excluded? = excluded_at.present?
  def excluded = excluded?

  # Assign a desired state, rather than flipping it: submitting the same
  # form twice must not reinstate a pollster or change the exclusion date.
  def excluded=(value)
    self.excluded_at = ActiveModel::Type::Boolean.new.cast(value) ? (excluded_at || Time.current) : nil
  end

  def self.exclusion_snapshot
    excluded.order(:id).map do |pollster|
      {
        "id" => pollster.id, "name" => pollster.name,
        "reason" => pollster.exclusion_reason, "source_url" => pollster.exclusion_source_url,
        "excluded_at" => pollster.excluded_at.iso8601(6)
      }
    end
  end

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

  private
    def clear_exclusion_details
      self.exclusion_reason = nil
      self.exclusion_source_url = nil
    end

    def refresh_forecast
      # Race fragments include the race timestamp; their poll lists and
      # scatter plots must change before the queued forecast completes.
      Race.where(id: polls.select(:race_id)).touch_all
      Forecast::RunJob.perform_later(trigger: :pollster_change)
    end
end
