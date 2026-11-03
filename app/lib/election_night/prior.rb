require "time"

class ElectionNight::Prior
  POLL_CLOSE_CUTOFF = Time.iso8601("2026-11-03T23:00:00Z").freeze

  # Freeze exactly once. Late poll refreshes must not masquerade as election
  # returns. This class only reads the existing forecasting tables.
  def self.capture
    run = ModelRun.succeeded.where("finished_at < ?", POLL_CLOSE_CUTOFF).latest.first
    raise "A completed pre-election forecast is required" unless run
    params = run.params_snapshot.deep_stringify_keys
    errors = params.fetch("error_model")
    chambers = params.fetch("chambers")
    forecasts = run.forecasts.excl_internals.includes(race: :candidates).to_a
    counts = forecasts.group_by { |f| f.race.office }.transform_values(&:size)
    raise "Freeze requires the complete 435 House / 35 Senate board" unless counts == { "house" => 435, "senate" => 35 }

    races = forecasts.map do |forecast|
      race = forecast.race
      model = Forecast::RaceModel.new(race: race, national_env: 0, averager: nil)
      key = if race.office == "senate"
        "#{race.state}-S"
      elsif race.district.to_i.zero?
        "#{race.state}-AL"
      else
        format("%s-%02d", race.state, race.district)
      end
      {
        "race_key" => key,
        "state" => race.state, "chamber" => race.office,
        "historical_house_compatible" => race.house? && !Forecast::HouseBaselines.current.changed?(race),
        "mu" => forecast.mean_margin.to_f,
        "sigma" => errors.fetch(race.house? ? "sigma_district" : (forecast.effective_poll_weight.to_f.positive? ? "sigma_senate_polled" : "sigma_senate_unpolled")),
        "side_a" => model.side_a.to_h.stringify_keys.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v },
        "side_b" => model.side_b.to_h.stringify_keys.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v },
        "certain" => model.certain_side&.to_h&.stringify_keys&.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }
      }
    end
    vp = chambers.fetch("vp_party")
    {
      "as_of" => run.finished_at.iso8601, "model_run_id" => run.id,
      "races" => races.sort_by { |r| r.fetch("race_key") },
      "sigma_national" => errors.fetch("sigma_national"), "sigma_state" => errors.fetch("sigma_state"),
      "sigma_regional" => errors.fetch("sigma_regional"),
      "house_majority" => chambers.fetch("house_majority_seats"),
      "senate_dem_holdover" => chambers.fetch("senate_holdover_dem_caucus"),
      "senate_rep_holdover" => chambers.fetch("senate_holdover_rep"),
      "senate_dem_threshold" => vp == "dem" ? 50 : 51,
      "senate_rep_threshold" => vp == "rep" ? 50 : 51
    }
  end

  # A valid but old local prior is useful for development; disclose its age
  # instead of silently presenting it as the final election-day forecast.
  def self.freshness(prior, now: Time.current)
    timestamp = Time.iso8601(prior.fetch("as_of"))
    raise ArgumentError, "Frozen prior must precede first poll close" unless timestamp < POLL_CLOSE_CUTOFF
    raise ArgumentError, "Frozen prior timestamp is in the future" if timestamp > now

    age_at_close = (POLL_CLOSE_CUTOFF - timestamp) / 3600.0
    {
      "prior_age_hours" => ((now - timestamp) / 3600.0).round(1),
      "prior_age_at_poll_close_hours" => age_at_close.round(1),
      "prior_is_old" => age_at_close > 24,
      "prior_warning" => age_at_close > 24 ? "The frozen pre-election forecast is #{(age_at_close / 24).round(1)} days before first poll close; uncovered races may reflect outdated polling and candidate assumptions." : nil
    }
  end
end
