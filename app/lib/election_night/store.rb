require "json"
require "fileutils"
require "digest"

# A single writer and atomic public snapshots. Keep this directory on a shared
# persistent volume when web and collector run in separate processes/hosts.
class ElectionNight::Store
  attr_reader :root

  def initialize(root: ENV.fetch("ELECTION_NIGHT_STORAGE", Rails.root.join("storage/election_night").to_s))
    @root = Pathname.new(root)
  end

  def read(name)
    path = root.join("#{name}.json")
    JSON.parse(path.read) if path.exist?
  end

  def latest = read("latest")

  def write(name, data)
    path = root.join("#{name}.json")
    FileUtils.mkdir_p(path.dirname)
    temp = "#{path}.#{Process.pid}.tmp"
    File.write(temp, JSON.generate(data))
    File.rename(temp, path)
    data
  ensure
    File.delete(temp) if temp && File.exist?(temp)
  end

  def archive(id, body)
    digest = Digest::SHA256.hexdigest(body)
    path = root.join("raw", id, digest)
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, body) unless path.exist?
    digest
  end

  def locked
    FileUtils.mkdir_p(root)
    File.open(root.join("collector.lock"), "w") do |file|
      raise "Election-night collector already running" unless file.flock(File::LOCK_EX | File::LOCK_NB)
      yield
    ensure
      file.flock(File::LOCK_UN)
    end
  end
end
