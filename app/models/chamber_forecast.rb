class ChamberForecast < ApplicationRecord
  enum :chamber, { senate: 0, house: 1 }
  enum :variant, { excl_internals: 0, incl_internals: 1 }, default: :excl_internals

  belongs_to :model_run
end
