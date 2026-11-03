class ElectionNight::Runner
  ASSUMPTIONS = [
    "Experimental model; election-night probabilities have not been calibrated against historical reporting sequences.",
    "2024 county presidential results and House results on verified unchanged district lines supply geographic baselines; expected two-party turnout is 75% of 2024, with wide reporting-order uncertainty.",
    "Direct updates require every county in a verified race manifest, at least 50% geographic coverage, 5,000 counted two-party votes and 15% estimated turnout. House updates additionally require historical district results on verified unchanged boundaries.",
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
      builder = ElectionNight::Observations.new(prior: prior, sources: sources)
      observations = builder.call
      result = ElectionNight::Nowcast.new(prior: prior, observations: observations, n_sims: @n_sims, seed: 5352026).call
      result.fetch("races").each do |race|
        race.merge!(builder.coverage.fetch(race.fetch("race_key"), {}))
      end
      stamp = Time.current.iso8601
      payload = result.merge(
        "generated_at" => stamp, "prior_as_of" => prior.fetch("as_of"),
        "status" => sources.any? { |s| s["usable"] && s["status"] != "ok" } ? "stale" : (observations.empty? ? "awaiting_results" : "experimental"),
        "sources" => sources.map { |s| s.except("results", "baseline", "usable") },
        "coverage" => {
          "races_with_returns" => observations.size, "races_total" => prior.fetch("races").size,
          "races_with_baselines" => builder.coverage.values.count { |v| v["has_baseline"] },
          "races_with_raw_returns" => builder.coverage.values.count { |v| v["observed_votes"].positive? }
        }, "assumptions" => ASSUMPTIONS + [ prior_freshness["prior_warning"] ].compact,
        "input_hashes" => sources.to_h { |s| [ s["id"], s.slice("raw_hash", "baseline_hash", "metadata_hash") ] },
        "observations" => observations
      ).merge(prior_freshness)
      @store.write("history/#{Time.current.utc.strftime('%Y%m%dT%H%M%S%6N')}", payload)
      @store.write("latest", payload)
    end
  end
end
