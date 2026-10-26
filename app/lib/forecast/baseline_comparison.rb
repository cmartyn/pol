# Paired simulations using one read-only database snapshot. This deliberately
# does not invoke Runner: successful ModelRuns are public immediately.
class Forecast::BaselineComparison
  def self.call(**options) = new(**options).call

  def initialize(as_of: Date.current, seed: 20261025, n_sims: nil, require_complete_house: true)
    @as_of, @seed, @n_sims = as_of.to_date, seed, n_sims
    @require_complete_house = require_complete_house
  end

  def call
    ActiveRecord::Base.transaction(isolation: :repeatable_read) do
      ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
      calculate
    end
  end

  private
    def calculate
      catalog = Forecast::HouseBaselines.current
      races = Race.where(office: Forecast::Runner::MODELLED_OFFICES).includes(:candidates).order(:id).to_a
      catalog.validate_board!(races) if @require_complete_house
      exclusions = Pollster.exclusion_snapshot
      excluded_ids = exclusions.map { |row| row.fetch("id") }
      polls = Poll.model_corpus(excluded_ids).includes(:poll_results).order(:id).to_a
      by_race = polls.group_by(&:race_id)
      effects = Forecast::HouseEffects.call(as_of: @as_of, excluded_pollster_ids: excluded_ids)
      internals = Forecast::Internals.estimate(as_of: @as_of, excluded_pollster_ids: excluded_ids)
      variants = { excl_internals: :exclude, incl_internals: :adjusted }.to_h do |variant, treatment|
        averager = Forecast::Averager.new(as_of: @as_of, house_effects: effects.lookup,
          internals: treatment, internals_shift: internals.shift, excluded_pollster_ids: excluded_ids)
        generic = averager.for_generic_ballot(polls: by_race.fetch(nil, []))
        environment = generic.mean_margin || Pol::Params.fetch!(:fundamentals, :house_national_margin_2024)
        models = [ true, false ].map do |legacy|
          races.map do |race|
            Forecast::RaceModel.new(race: race, national_env: environment, averager: averager,
              polls: by_race.fetch(race.id, []), house_baseline: race.house? ? catalog.resolve(race, legacy: legacy) : nil)
          end
        end
        simulations = models.map do |board|
          Forecast::Simulator.new(entries: board.map(&:to_entry), seed: @seed, as_of: @as_of, n_sims: @n_sims).call
        end
        [ variant, { national_env: environment, races: race_changes(races, models, simulations, catalog),
          chambers: simulations.map { |simulation| simulation.chambers.map(&:to_h) } } ]
      end
      inputs = {
        races: races.map { |race| race.attributes.merge("candidates" => race.candidates.map(&:attributes)) },
        polls: polls.map { |poll| poll.attributes.merge("results" => poll.poll_results.map(&:attributes)) },
        exclusions: exclusions, house_effects: effects.lookup, internals: internals.to_snapshot,
        baselines: catalog.snapshot(races), parameters: Pol::Params.to_h
      }
      { as_of: @as_of.iso8601, seed: @seed, n_sims: @n_sims || Pol::Params.fetch!(:simulation, :n_sims),
        input_digest: Digest::SHA256.hexdigest(JSON.generate(inputs)), inputs: inputs, variants: variants }
    end

    def race_changes(races, models, simulations, catalog)
      outcomes = simulations.map { |simulation| simulation.races.index_by(&:race_id) }
      races.each_with_index.map do |race, index|
        { race: race.slug, state: race.state, changed: catalog.changed?(race),
          before: detail(models.first[index], outcomes.first.fetch(race.id)),
          after: detail(models.last[index], outcomes.last.fetch(race.id)) }
      end
    end

    def detail(model, outcome)
      { baseline: model.house_baseline&.to_snapshot, prior: model.prior, mu: model.mu,
        poll_weight: model.average.weight, p_dem_win: outcome.p_dem_win,
        p_rep_win: outcome.p_rep_win, percentiles: outcome.percentiles }
    end
end
