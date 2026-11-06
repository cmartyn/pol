# Old GoodJob entries can already be queued when the schedule switches.
class PreElectionJob < ApplicationJob
  before_enqueue { throw :abort if ForecastArchive.active? }
  before_perform { throw :abort if ForecastArchive.active? }
end
