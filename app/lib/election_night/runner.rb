class ElectionNight::Runner
  ASSUMPTIONS = [
    "Experimental model; election-night probabilities have not been calibrated against historical reporting sequences.",
    "2024 county presidential results and actual House district portions supply partisan baselines. Verified same-geography 2022 Senate totals anchor midterm turnout where available; other units assume 75% of 2024 candidate votes.",
    "Outstanding votes are assumption-based scenario ranges, not official ballot inventories or calibrated confidence intervals. Counted votes stay fixed; correlated turnout and reporting-order scenarios project only the remaining votes.",
    "Direct updates require every county in an independent race manifest, at least 50% represented historical geography, 5,000 counted two-party votes and at least 15% counted even at the scenario range's high turnout bound. House updates require verified unchanged boundaries.",
    "House districts without a complete unchanged-line historical manifest, ranked-choice contests and independent matchups retain their prior or receive only shared updates; their raw returns do not directly condition this model.",
    "Shared state reporting-bias factors keep multiple races based on similar early batches from being treated as independent proof of a voter swing.",
    "Sources are unofficial returns. A probability is not a race call; missing sources are not zero votes."
  ].freeze

  def initialize(store: ElectionNight::Store.new, n_sims: 10_000)
    @store, @n_sims = store, n_sims
  end

  def call
    @store.locked do
      prior = @store.read("prior")
      raise "Freeze the pre-election prior first: bin/rails election_night:freeze" unless prior
      counts = prior.fetch("races").group_by { |r| r.fetch("chamber") }.transform_values(&:size)
      raise "A complete 435 House / 35 Senate prior is required" unless counts == { "house" => 435, "senate" => 35 }
      prior_freshness = ElectionNight::Prior.freshness(prior)
      sources = ElectionNight::Collector.new(store: @store).call
      historical = ElectionNight::HistoricalBaselines.new.call
      builder = ElectionNight::Observations.new(prior: prior, sources: sources, historical: historical)
      observations = builder.call
      result = ElectionNight::Nowcast.new(prior: prior, observations: observations, n_sims: @n_sims, seed: 5352026).call
      result.fetch("races").each do |race|
        race.merge!(builder.coverage.fetch(race.fetch("race_key"), {}))
      end
      stamp = Time.current.iso8601
      used_ids = builder.coverage.values.flat_map { |race| Array(race["raw_source_ids"]) } +
        observations.flat_map { |observation| observation.fetch("source_ids") }
      stale = sources.any? { |source| used_ids.include?(source["id"]) && source["usable"] && %w[error stale].include?(source["status"]) }
      payload = result.merge(
        "generated_at" => stamp, "prior_as_of" => prior.fetch("as_of"),
        "status" => stale ? "stale" : (observations.empty? ? "awaiting_results" : "experimental"),
        "sources" => sources.map { |s| s.except("results", "baseline", "usable") },
        "coverage" => ElectionNight::Coverage.new(races: result.fetch("races"), sources: sources).summary,
        "assumptions" => ASSUMPTIONS + [ prior_freshness["prior_warning"] ].compact,
        "input_hashes" => sources.to_h { |s| [ s["id"], s.slice("raw_hash", "baseline_hash", "metadata_hash", "version_hash") ] },
        "historical_baselines" => historical.fetch("provenance").except("source_catalog").merge("revision" => historical.fetch("revision")),
        "outstanding_votes_model" => ElectionNight::OutstandingVotes::VERSION,
        "county_rejections" => builder.county_rejections,
        "observations" => observations
      ).merge(prior_freshness)
      @store.write("history/#{Time.current.utc.strftime('%Y%m%dT%H%M%S%6N')}", payload)
      @store.write("latest", payload)
    end
  end
end
