require "json"

# Raw-source scope is independent of eligibility to condition the forecast.
class ElectionNight::Coverage
  COMPLETE_LEVELS = %w[county contest].freeze

  def initialize(races:, sources:, watchlist: JSON.parse(Rails.root.join("config/election_night_watchlist.json").read))
    @races, @sources, @watchlist = races, sources, watchlist
  end

  def summary
    watched = @races.select { |race| @watchlist.fetch("race_keys").include?(race.fetch("race_key")) }
    {
      "races_total" => @races.size,
      "races_with_returns" => @races.count { |race| race["direct_observation"] },
      "races_with_baselines" => @races.count { |race| race["has_baseline"] },
      "races_with_raw_returns" => @races.count { |race| race.fetch("observed_votes", 0).positive? },
      "races_with_raw_sources" => @races.count { |race| complete?(race) },
      "competitive_races_total" => @watchlist.fetch("race_keys").size,
      "competitive_races_with_raw_sources" => watched.count { |race| complete?(race) },
      "competitive_races_with_county_sources" => watched.count { |race| race["raw_coverage_level"] == "county" },
      "competitive_races_with_contest_sources" => watched.count { |race| race["raw_coverage_level"] == "contest" },
      "competitive_races_with_partial_sources" => watched.count { |race| race["raw_coverage_level"] == "partial" }
    }
  end

  def report
    sources = @sources.index_by { |source| source.fetch("id") }
    rows = @races.map do |race|
      selected = Array(race["raw_source_ids"]).filter_map { |id| sources[id] }
      race.slice("race_key", "chamber", "state", "raw_coverage_level", "raw_reporting_units", "observed_votes",
        "raw_source_ids", "raw_source_published_at", "raw_source_stale", "has_baseline", "reason").merge(
          "competitive" => @watchlist.fetch("race_keys").include?(race.fetch("race_key")),
          "source_kinds" => selected.map { |source| source["source_kind"] }.compact.uniq,
          "source_urls" => selected.map { |source| source["url"] }
        )
    end.sort_by { |race| race.fetch("race_key") }
    { "watchlist" => @watchlist, "summary" => summary, "races" => rows }
  end

  private
    def complete?(race) = COMPLETE_LEVELS.include?(race["raw_coverage_level"])
end
