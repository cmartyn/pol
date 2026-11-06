# The checked-in download is the published November 3 run and its ballot
# roster. The same pin selects the database rows used by the existing charts.
module ForecastArchive
  PATH = "/archives/2026-11-03-forecast.json"
  Candidate = Data.define(:id, :name, :party, :incumbent, :caucus_with) do
    alias_method :incumbent?, :incumbent
  end

  module_function

  def active? = Rails.configuration.x.post_election
  def data = @data ||= JSON.parse(Rails.public_path.join(PATH.delete_prefix("/")).read)
  def run_id = data.fetch("model_run").fetch("id")
  def finished_at = @finished_at ||= Time.iso8601(data.fetch("model_run").fetch("finished_at"))
  def started_at = @started_at ||= Time.iso8601(data.fetch("model_run").fetch("started_at"))
  def polling_time = active? ? started_at.in_time_zone : Time.current
  def excluded_pollster_ids = active? ? data.fetch("model_run").fetch("excluded_pollster_ids") : nil
  def races = data.fetch("races")

  def uncontested_party(race)
    if active?
      row = races[race.slug]
      row["uncontested_party"] if row && row["uncontested"]
    elsif race.uncontested?
      race.uncontested_party
    end
  end

  def candidates(slug)
    # The archive orders candidates by their original ID, the model's
    # tiebreaker between two minor candidates of the same party.
    races.fetch(slug).fetch("candidates").map.with_index do |row, index|
      Candidate.new(index, *row.values_at("name", "party", "incumbent", "caucus_with"))
    end
  end

  # Check the database behind the charts against the downloadable record
  # before the new container starts serving. SQL uniqueness covers each
  # race/variant and chamber/variant pair, so the counts prove coverage.
  def verify!
    run = ModelRun.published.sole
    raise "Final forecast metadata differs" unless run.started_at == started_at &&
      run.n_sims == data.dig("model_run", "simulations") && run.rng_seed.to_s == data.dig("model_run", "rng_seed")

    forecasts = run.forecasts.joins(:race).select("forecasts.*, races.slug AS race_slug").to_a
    raise "Incomplete final race forecasts" unless forecasts.size == races.sum { |_slug, race| race.fetch("forecasts").size }
    forecasts.each do |forecast|
      saved = races.fetch(forecast.race_slug).fetch("forecasts").fetch(forecast.variant)
      raise "Forecast differs for #{forecast.race_slug} #{forecast.variant}" unless forecast.slice(*saved.keys) == saved
    end
    chambers = data.fetch("chambers")
    raise "Incomplete final chamber forecasts" unless run.chamber_forecasts.size == chambers.values.sum(&:size)
    run.chamber_forecasts.each do |forecast|
      saved = chambers.fetch(forecast.chamber).fetch(forecast.variant)
      raise "Forecast differs for #{forecast.chamber} #{forecast.variant}" unless forecast.slice(*saved.keys) == saved
    end
    run
  end
end
