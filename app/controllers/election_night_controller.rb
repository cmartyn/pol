require "digest"

class ElectionNightController < PublicController
  before_action :load_snapshot
  helper_method :night_probability, :night_time, :night_status, :night_needle_point, :night_race_status, :night_prior_old?, :night_raw_coverage,
    :night_outstanding_estimate, :night_estimate_votes, :night_reported_votes?

  def index
  end

  def snapshot
    render json: (@snapshot || {}).merge("status" => night_status, "revision" => @revision)
  end

  private
    def load_snapshot
      response.headers["Cache-Control"] = "no-store"
      response.headers["CDN-Cache-Control"] = "no-store"
      response.headers["X-Robots-Tag"] = "noindex, nofollow"
      store = ElectionNight::Store.new
      @snapshot = store.latest || ElectionNight::PreElectionSnapshot.new(prior: store.read("prior")).call
      @revision = Digest::SHA256.hexdigest([ @snapshot.to_json, night_status ].join)
      @coverage = @snapshot&.fetch("coverage", {}) || {}
      @sources = Array(@snapshot&.fetch("sources", []))
      @races = Array(@snapshot&.fetch("races", [])).sort_by do |race|
        [ %w[returns returns_updated].include?(race["status"]) ? 0 : 1, (race["p_dem_win"].to_f - 0.5).abs, race["race_key"].to_s ]
      end
    end

    def night_probability(value)
      return "—" unless value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
      return "<1%" if value < 0.01
      return ">99%" if value > 0.99

      "#{(value * 100).round}%"
    end

    def night_time(value)
      return "Not yet available" if value.blank?
      return Date.iso8601(value).strftime("%b %-d, %Y") if value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Time.iso8601(value).in_time_zone("America/New_York").strftime("%b %-d, %-I:%M %p %Z")
    rescue ArgumentError, TypeError
      "Not yet available"
    end

    def night_status
      return "unavailable" unless @snapshot
      return "archived" if ForecastArchive.active?
      # A saved polling forecast is the starting point, not a stale returns
      # feed. Its real date remains visible while we wait for the first sweep.
      return "pre_election" if @snapshot["status"] == "pre_election"
      return "stale" if @snapshot["status"] == "stale"

      generated = Time.iso8601(@snapshot.fetch("generated_at", ""))
      return "stale" if generated < 10.minutes.ago

      @snapshot.fetch("status", "experimental")
    rescue ArgumentError, TypeError
      "stale"
    end

    def night_prior_old?
      value = @snapshot&.fetch("prior_as_of", nil)
      return false if value.blank?

      frozen_at = if value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(value).in_time_zone("America/New_York")
      else
        Time.iso8601(value)
      end
      frozen_at < 48.hours.ago
    rescue ArgumentError, TypeError
      false
    end

    def night_needle_point(probability)
      angle = Math::PI * (1 - probability)
      [ (180 + 132 * Math.cos(angle)).round(2), (164 - 132 * Math.sin(angle)).round(2) ]
    end

    def night_race_status(status)
      case status
      when "returns", "returns_updated" then "Returns + prior"
      when "shared_update" then "Related races + prior"
      when "uncontested" then "Uncontested"
      else "Pre-election forecast"
      end
    end

    def night_reported_votes?(race)
      votes = race["observed_votes"]
      race["has_raw_source"] != false && votes.is_a?(Numeric) && votes.finite? && votes.positive?
    end

    def night_raw_coverage(race)
      return "No raw source" if race["has_raw_source"] == false

      label = { "county" => "County detail", "contest" => "Contest total", "partial" => "Partial coverage" }[race["raw_coverage_level"]]
      return unless label

      [ label, ("fallback" if race["raw_source_fallback"]), ("delayed" if race["raw_source_stale"]) ].compact.join(" · ")
    end

    def night_outstanding_estimate(race)
      estimate = race["outstanding_votes"]
      return unless estimate.is_a?(Hash)
      point, low, high = estimate.values_at("remaining_votes", "remaining_votes_low", "remaining_votes_high")
      return unless [ point, low, high ].all? { |value| value.is_a?(Numeric) && value.finite? && value >= 0 }
      return unless low <= point && point <= high

      estimate
    end

    def night_estimate_votes(value, rounding: :round)
      step = value >= 1000 ? 100 : 1
      rounded = (value.to_f / step).public_send(rounding) * step
      return "<1" if rounding == :round && value.positive? && rounded.zero?

      helpers.number_with_delimiter(rounded)
    end
end
