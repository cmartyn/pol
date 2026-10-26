namespace :pol do
  desc "Validate and list all 435 district baseline decisions (read-only)"
  task audit_baselines: :environment do
    puts JSON.pretty_generate(Forecast::HouseBaselines.current.audit)
  end

  desc "Compare old and corrected baselines without publishing (AS_OF, SEED, N_SIMS optional)"
  task compare_baselines: :environment do
    report = Forecast::BaselineComparison.call(
      as_of: ENV.fetch("AS_OF", Date.current.iso8601),
      seed: Integer(ENV.fetch("SEED", "20261025")),
      n_sims: ENV["N_SIMS"] && Integer(ENV.fetch("N_SIMS"))
    )
    puts JSON.pretty_generate(report)
  end
end
