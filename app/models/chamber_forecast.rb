class ChamberForecast < ApplicationRecord
  enum :chamber, { senate: 0, house: 1 }

  belongs_to :model_run
end
