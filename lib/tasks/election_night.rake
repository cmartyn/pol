namespace :election_night do
  desc "Freeze a complete pre-election prior once (read-only access to forecast tables)"
  task freeze: :environment do
    store = ElectionNight::Store.new
    store.locked do
      abort "Prior already frozen; use a new ELECTION_NIGHT_STORAGE directory for a separate experiment" if store.read("prior")
      prior = ElectionNight::Prior.capture
      store.write("prior", prior)
      puts "Frozen #{prior.fetch('races').size} races from model run #{prior.fetch('model_run_id')}"
    end
  end

  desc "Collect official returns and atomically publish our experimental needle snapshot once"
  task sweep: :environment do
    result = ElectionNight::Runner.new.call
    puts "#{result.fetch('status')}: #{result.dig('coverage', 'races_with_returns')} races directly updated"
  end
end
