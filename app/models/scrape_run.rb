class ScrapeRun < ApplicationRecord
  enum :status, { succeeded: 0, failed: 1, partial: 2 }
end
