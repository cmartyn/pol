class PostElection::Sync
  def initialize(store: ElectionNight::Store.new)
    @store = store
    @catalog = ElectionNight::CivicCatalog.new
  end

  def call(slug: nil)
    @store.locked do
      sources = due_sources(slug)
      fetched = ElectionNight::Collector.new(store: @store).collect_civic(sources)
      import(fetched, refresh_certified: slug.present?)
    end
  end

  # At cutover, reuse immutable raw files collected before this release.
  # No network access or waits on the old worker's full-board sweep.
  def import_saved
    saved = @catalog.sources.filter_map do |source|
      next if races.fetch(source.fetch("expected_races").sole).race_result&.reported_at
      @store.read("sources/#{source.fetch('id')}")
    end
    import(saved, retained: true)
  end

  private
    def due_sources(slug)
      if slug
        key = ForecastArchive.races.fetch(slug).fetch("race_key")
        return @catalog.sources.select { |source| source.fetch("expected_races") == [ key ] }
      end

      @catalog.sources.select do |source|
        result = races.fetch(source.fetch("expected_races").sole).race_result
        result.nil? || result.due?
      end
    end

    def races
      @races ||= Race.where(slug: ForecastArchive.races.keys).includes(:race_result).index_by do |race|
        ForecastArchive.races.fetch(race.slug).fetch("race_key")
      end
    end

    def import(sources, retained: false, refresh_certified: false)
      failures = []
      sources.each do |source|
        key = source.fetch("expected_races").sole
        unless source["usable"] && (source["status"] == "ok" || retained)
          failures << "#{key}: #{source['collection_skipped'] || source['error'] || "status #{source['status']}"}"
          next
        end
        race = races.fetch(key)
        id = "civic_#{key.downcase.tr('-', '_')}"
        hash = source.fetch("raw_hash")
        raise ArgumentError, "Unexpected archived source" unless source["id"] == id && hash.match?(/\A[0-9a-f]{64}\z/)
        body = File.binread(@store.root.join("raw", id, hash))
        raise ArgumentError, "Raw checksum mismatch" unless Digest::SHA256.hexdigest(body) == hash

        fetched_at = Time.iso8601(source.fetch("fetched_at"))
        entry = catalog_by_key.fetch(key)
        url = "https://civicapi.org/results/elections/#{entry.fetch('id')}"
        report = PostElection::CivicReport.new(state: entry.fetch("state")).read(body, race_key: key, url: url, fetched_at: fetched_at)
        result = race.race_result || RaceResult.for_race!(race)
        result.import!(report, fetched_at: fetched_at, refresh_certified: refresh_certified)
      rescue ElectionNight::Sources::Base::InvalidData, ArgumentError, KeyError, Errno::ENOENT => error
        Rails.logger.warn("Post-election results #{key}: #{error.message.truncate(200)}")
        failures << "#{key}: #{error.class.name}: #{error.message.truncate(100)}"
      end
      Rails.logger.info("Post-election results: #{sources.size - failures.size}/#{sources.size} reports accepted")
      raise "Failed result sources: #{failures.join('; ')}" if failures.any? && !retained
      sources.size - failures.size
    end

    def catalog_by_key = @catalog_by_key ||= @catalog.races.index_by { |entry| entry.fetch("race_key") }
end
