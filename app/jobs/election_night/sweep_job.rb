class ElectionNight::SweepJob < ApplicationJob
  queue_as :election_night

  def perform
    return unless ENV["ELECTION_NIGHT_ENABLED"] == "true"
    ElectionNight::Runner.new.call
  end
end
