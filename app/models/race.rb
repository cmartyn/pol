class Race < ApplicationRecord
  # Full state name for every state plus DC. Used by #name to render Senate
  # and Governor races as "Maine Senate"; House races use the 2-letter code
  # directly ("NY-17") and don't need this.
  STATE_NAMES = {
    "AL" => "Alabama", "AK" => "Alaska", "AZ" => "Arizona", "AR" => "Arkansas",
    "CA" => "California", "CO" => "Colorado", "CT" => "Connecticut", "DE" => "Delaware",
    "FL" => "Florida", "GA" => "Georgia", "HI" => "Hawaii", "ID" => "Idaho",
    "IL" => "Illinois", "IN" => "Indiana", "IA" => "Iowa", "KS" => "Kansas",
    "KY" => "Kentucky", "LA" => "Louisiana", "ME" => "Maine", "MD" => "Maryland",
    "MA" => "Massachusetts", "MI" => "Michigan", "MN" => "Minnesota", "MS" => "Mississippi",
    "MO" => "Missouri", "MT" => "Montana", "NE" => "Nebraska", "NV" => "Nevada",
    "NH" => "New Hampshire", "NJ" => "New Jersey", "NM" => "New Mexico", "NY" => "New York",
    "NC" => "North Carolina", "ND" => "North Dakota", "OH" => "Ohio", "OK" => "Oklahoma",
    "OR" => "Oregon", "PA" => "Pennsylvania", "RI" => "Rhode Island", "SC" => "South Carolina",
    "SD" => "South Dakota", "TN" => "Tennessee", "TX" => "Texas", "UT" => "Utah",
    "VT" => "Vermont", "VA" => "Virginia", "WA" => "Washington", "WV" => "West Virginia",
    "WI" => "Wisconsin", "WY" => "Wyoming", "DC" => "District of Columbia"
  }.freeze

  enum :office, { senate: 0, house: 1, governor: 2 }

  # Both use the same dem/rep/ind/other value set as candidates/poll_results,
  # and both live on this table, so each needs its own prefix to avoid
  # generating clashing predicate methods (dem?, rep?, ...) for the other.
  enum :incumbent_party, { dem: 0, rep: 1, ind: 2, other: 3 }, prefix: :incumbent
  enum :uncontested_party, { dem: 0, rep: 1, ind: 2, other: 3 }, prefix: :uncontested

  has_many :candidates
  has_many :polls
  has_many :forecasts
  has_many :dispatches

  validates :state, presence: true, format: { with: /\A[A-Z]{2}\z/, message: "must be a 2-letter code" }
  validates :slug, presence: true, uniqueness: true
  validates :district, presence: true, if: :house?

  # Display name: "Maine Senate" / "Maine Governor" for statewide races,
  # "NY-17" for House races.
  def name
    if house?
      "#{state}-#{district}"
    else
      "#{STATE_NAMES.fetch(state, state)} #{office.capitalize}"
    end
  end

  # The forecast from the most recent *succeeded* model run, or nil if none
  # exists yet. Rendering many races at once (Phase 4 list pages) should
  # prefer Forecast.latest_for_races directly instead of calling this in a
  # loop, to avoid N+1 queries.
  def latest_forecast(variant: :excl_internals)
    Forecast.latest_for_races(variant: variant).find_by(race_id: id)
  end
end
