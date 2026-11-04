# Read the published polling forecast while the election-night collector has no
# snapshot. A frozen run ID is a pin, never permission to substitute a newer run.
class ElectionNight::PreElectionSnapshot
  def initialize(prior: nil)
    @prior = prior
  end

  def call
    run = selected_run
    return unless run

    records = run.chamber_forecasts.excl_internals.index_by(&:chamber)
    return unless %w[house senate].all? { |chamber| valid_chamber?(records[chamber], chamber) }

    races = run.forecasts.excl_internals.includes(:race).map { |forecast| race_output(forecast) }
    return if races.any?(&:nil?) || races.map { |race| race["race_key"] }.uniq.size != races.size

    {
      "model_version" => "pre_election_forecast", "status" => "pre_election",
      "generated_at" => run.finished_at.iso8601, "prior_as_of" => run.finished_at.iso8601,
      "prior_model_run_id" => run.id,
      "chambers" => records.transform_values do |record|
        record.slice("p_dem_control", "p_rep_control", "mean_dem_seats", "seat_histogram").merge(
          "p_unresolved_control" => [ 1.0 - record.p_dem_control - record.p_rep_control, 0.0 ].max)
      end,
      "races" => races.sort_by { |race| race.fetch("race_key") },
      "sources" => [], "input_hashes" => {},
      "coverage" => {
        "races_total" => races.size, "races_with_returns" => 0, "races_with_baselines" => 0,
        "races_with_raw_returns" => 0, "races_with_raw_sources" => 0, "races_with_outstanding_estimates" => 0
      },
      "diagnostics" => { "experimental" => true, "observed_races" => 0, "unobserved_races" => races.size },
      "assumptions" => [ "These are the saved pre-election polling forecast values, excluding partisan-sponsored polls. No election-night returns have entered this snapshot; the live forecast will replace it when published." ]
    }
  end

  private
    def selected_run
      eligible = ModelRun.succeeded.where("finished_at < ?", ElectionNight::Prior::POLL_CLOSE_CUTOFF)
      return eligible.latest.first if @prior.nil?
      return unless @prior.is_a?(Hash)

      id = @prior["model_run_id"]
      return unless (id.is_a?(Integer) && id.positive?) || (id.is_a?(String) && id.match?(/\A[1-9]\d*\z/))

      eligible.find_by(id: id)
    end

    def finite?(value) = value.is_a?(Numeric) && value.finite?
    def probability?(value) = finite?(value) && value.between?(0, 1)

    def valid_chamber?(record, chamber)
      return false unless record
      return false unless [ record.p_dem_control, record.p_rep_control ].all? { |value| probability?(value) }
      return false if record.p_dem_control + record.p_rep_control > 1.0 + 1e-9

      finite?(record.mean_dem_seats) && record.mean_dem_seats.between?(0, chamber == "house" ? 435 : 100)
    end

    def race_output(forecast)
      race = forecast.race
      return unless race && %w[house senate].include?(race.office)
      probabilities = [ forecast.p_dem_win, forecast.p_rep_win, forecast.p_other_win ]
      return unless probabilities.all? { |value| probability?(value) } && (probabilities.sum - 1).abs <= 1e-9
      return unless finite?(forecast.mean_margin)

      key = if race.senate?
        "#{race.state}-S"
      elsif %w[AK DE ND SD VT WY].include?(race.state) || race.district.to_i.zero?
        "#{race.state}-AL"
      else
        format("%s-%02d", race.state, race.district)
      end
      {
        "race_key" => key, "state" => race.state, "chamber" => race.office,
        "p_dem_win" => forecast.p_dem_win, "p_rep_win" => forecast.p_rep_win, "p_other_win" => forecast.p_other_win,
        "mean_margin" => forecast.mean_margin, "percentiles" => forecast.margin_percentiles,
        "status" => frozen_uncontested?(key, forecast) ? "uncontested" : "prior_only",
        "direct_observation" => false, "observed_votes" => nil, "has_raw_source" => false,
        "source_ids" => [], "raw_source_ids" => [], "raw_coverage_level" => nil, "outstanding_votes" => nil
      }
    end

    def frozen_uncontested?(key, forecast)
      return false unless @prior.is_a?(Hash) && @prior["races"].is_a?(Array)

      row = @prior["races"].find { |race| race.is_a?(Hash) && race["race_key"] == key }
      party = row&.dig("certain", "party") if row&.fetch("certain", nil).is_a?(Hash)
      return false unless party.is_a?(String) && !party.empty?

      column = { "dem" => "p_dem_win", "rep" => "p_rep_win" }.fetch(party, "p_other_win")
      forecast.public_send(column) == 1.0
    end
end
