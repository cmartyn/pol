#!/usr/bin/env ruby
require "pathname"
require "optparse"

module ElectionNight
  module Sources
  end
end

root = Pathname.new(__dir__).parent
%w[sources/base sources/civic_api store collector civic_catalog civic_validator].each do |file|
  require root.join("app/lib/election_night/#{file}").to_s
end

options = { reuse: [], delay: 0.25 }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/validate_election_night_civic.rb --store ABSOLUTE_PATH [--reuse-store ABSOLUTE_PATH]"
  parser.on("--store PATH", "Isolated output directory; resumable") { |v| options[:store] = v }
  parser.on("--reuse-store PATH", "Reparse archived bodies from a previous store") { |v| options[:reuse] << v }
  parser.on("--delay SECONDS", Float, "Minimum delay between new HTTP requests (default 0.25)") { |v| options[:delay] = v }
end.parse!
abort "--store must be an absolute path" unless options[:store] && Pathname.new(options[:store]).absolute?
abort "--delay must be at least 0.25 seconds" unless options[:delay] >= 0.25
abort "--reuse-store paths must be absolute" unless options[:reuse].all? { |p| Pathname.new(p).absolute? }
store = ElectionNight::Store.new(root: options[:store])
report = ElectionNight::CivicValidator.new(store: store,
  reuse_stores: options[:reuse].map { |p| ElectionNight::Store.new(root: p) }, delay: options[:delay]).call
puts JSON.generate(report.reject { |k, _| k == "sources" })
exit(report.fetch("failed").zero? ? 0 : 1)
