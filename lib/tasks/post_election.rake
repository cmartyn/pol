namespace :post_election do
  desc "Verify the final polling run and import retained public returns on first deploy"
  task prepare: :environment do
    abort "Set POST_ELECTION_MODE=true first" unless ForecastArchive.active?
    run = ForecastArchive.verify!
    puts "Final forecast ##{run.id}; imported #{PostElection::Sync.new.import_saved} saved result reports."
  end

  desc "Refresh due results, or one specified race (including after certification)"
  task :refresh, [ :slug ] => :environment do |_task, args|
    abort "Set POST_ELECTION_MODE=true first" unless ForecastArchive.active?
    puts "Accepted #{PostElection::Sync.new.call(slug: args[:slug])} result reports."
  end
end
