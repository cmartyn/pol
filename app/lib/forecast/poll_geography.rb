# District numbers survive redistricting; samples do not. Explicit source
# evidence overrides the feed assignment. Otherwise accept a NYT general-
# election question only when it identifies the current race and its entire
# field period follows adoption of that map. This is an aggregator assignment,
# not a claim that we independently inspected the pollster's voter file.
class Forecast::PollGeography
  def initialize
    @catalog = Forecast::HouseBaselines.current
  end

  def reason(poll, race: nil)
    return if poll.race_id.nil?

    race ||= races[poll.race_id]
    return unless race && @catalog.changed?(race)

    plan = @catalog.plan_for(race)
    explicit = poll.raw_payload&.fetch("district_plan", nil)
    if explicit.is_a?(Hash) && explicit["id"].present?
      return "District lines need a verification source" if explicit["source_url"].blank?

      return explicit["id"] == plan.fetch("id") ? nil : "Sample uses different district lines"
    end

    row = poll.raw_payload&.dig("nyt", "rows", 0)
    assigned = poll.nyt? && row && row["cycle"].to_s == race.cycle.to_s &&
      row["state"] == race.state && row["seat_number"].to_s == race.district.to_s &&
      row["stage"] == "general"
    after_adoption = poll.field_start && poll.field_start > Date.iso8601(plan.fetch("adopted_on"))
    return if assigned && after_adoption

    "District lines not established for this sample"
  end

  private
    def races
      @races ||= Race.house.select(:id, :office, :state, :district, :cycle).index_by(&:id)
    end
end
