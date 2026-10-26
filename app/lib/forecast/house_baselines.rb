require "csv"
require "digest"
require "yaml"

# The electorate is a model input. Historical House results stay on Race;
# changed districts use a versioned, checked-in source on the operative lines.
# Deploying a complete catalog is atomic and a legacy reseed cannot undo it.
class Forecast::HouseBaselines
  Invalid = Class.new(StandardError)
  DIRECTORY = Rails.root.join("db/seed_data/house_baselines/2026")
  LEGACY_REVISION = "house-results-2024-v1".freeze
  METHOD_VERSION = "presidential-lean-v1/poll-geography-v1".freeze
  SEATS = {
    "AL" => 7, "AK" => 1, "AZ" => 9, "AR" => 4, "CA" => 52, "CO" => 8, "CT" => 5,
    "DE" => 1, "FL" => 28, "GA" => 14, "HI" => 2, "ID" => 2, "IL" => 17, "IN" => 9,
    "IA" => 4, "KS" => 4, "KY" => 6, "LA" => 6, "ME" => 2, "MD" => 8, "MA" => 9,
    "MI" => 13, "MN" => 8, "MS" => 4, "MO" => 8, "MT" => 2, "NE" => 3, "NV" => 4,
    "NH" => 2, "NJ" => 12, "NM" => 3, "NY" => 26, "NC" => 14, "ND" => 1, "OH" => 15,
    "OK" => 5, "OR" => 6, "PA" => 17, "RI" => 2, "SC" => 7, "SD" => 1, "TN" => 9,
    "TX" => 38, "UT" => 4, "VT" => 1, "VA" => 11, "WA" => 10, "WV" => 2, "WI" => 8, "WY" => 1
  }.freeze

  CHANGED_STATE_FIPS = { "01" => "AL", "06" => "CA", "12" => "FL", "22" => "LA", "37" => "NC",
                         "39" => "OH", "47" => "TN", "48" => "TX", "49" => "UT" }.freeze

  Baseline = Data.define(:method, :margin, :national_margin, :plan_id, :source_url, :votes) do
    def presidential? = method == "presidential_lean"
    def imputed? = method == "imputed_house_result"
    def lean = margin - national_margin
    def label = presidential? ? "2024 president · 2026 lines" : "2024 House result"
    def to_snapshot = to_h.merge(year: 2024, units: "D-R percentage points, all votes")
  end

  def self.current
    @current ||= new
  end

  def initialize(directory: DIRECTORY)
    @directory = Pathname.new(directory)
    @manifest = YAML.safe_load_file(@directory.join("manifest.yml"))
    @current = read_votes("presidential_2024.csv")
    @old = read_votes("presidential_2024_old_lines.csv")
    @changed = @manifest.fetch("plans").flat_map do |state, plan|
      plan.fetch("changed_districts").map { |district| [ state, district ] }
    end
    validate!
    @revision = Digest::SHA256.hexdigest(METHOD_VERSION + @directory.join("manifest.yml").read)
  end

  attr_reader :revision

  def plan_ids
    @manifest.fetch("plans").transform_values { |plan| plan.fetch("id") }
  end

  def changed?(race)
    race.house? && race.cycle == @manifest.fetch("cycle") && @changed.include?([ race.state, race.district ])
  end

  def plan_for(race)
    @manifest.fetch("plans").fetch(race.state) if changed?(race)
  end

  def resolve(race, legacy: false)
    raise Invalid, "No verified House plans for #{race.cycle}" unless race.cycle == @manifest.fetch("cycle")

    if changed?(race) && !legacy
      votes = @current.fetch([ race.state, race.district ])
      Baseline.new(method: "presidential_lean", margin: margin(votes),
        national_margin: Pol::Params.fetch!(:fundamentals, :pres_national_margin_2024),
        plan_id: @manifest.fetch("plans").fetch(race.state).fetch("id"),
        source_url: @manifest.fetch("sources").fetch("presidential_2024.csv").fetch("url"), votes: votes)
    else
      value = race.baseline_margin
      raise Invalid, "Missing or invalid 2024 House baseline for #{race.slug}" unless value&.finite? && value.between?(-100, 100)

      Baseline.new(method: race.baseline_imputed? ? "imputed_house_result" : "house_result",
        margin: value, national_margin: Pol::Params.fetch!(:fundamentals, :house_national_margin_2024),
        plan_id: "#{race.state.downcase}-2024", source_url: race.baseline_source_url, votes: nil)
    end
  end

  # A complete production board is required before simulating House control.
  # Small fixture boards can exercise the same engine with this check disabled.
  def validate_board!(races)
    found = races.select(&:house?).map { |race| [ race.state, race.district ] }.sort
    raise Invalid, "House board must contain each of the 435 districts exactly once" unless found == @current.keys.sort

    races.select(&:house?).each { |race| resolve(race) }
  end

  def snapshot(races)
    { revision: revision, source_revision: @manifest.fetch("version"),
      races: races.select(&:house?).to_h { |race| [ race.id.to_s, resolve(race).to_snapshot ] } }
  end

  def audit
    @current.sort.map do |(state, district), votes|
      changed = @changed.include?([ state, district ])
      { state: state, district: district, changed: changed,
        method: changed ? "presidential_lean" : "historical_house",
        old_presidential_margin: margin(@old.fetch([ state, district ])),
        new_presidential_margin: margin(votes),
        plan_id: changed ? @manifest.fetch("plans").fetch(state).fetch("id") : "#{state.downcase}-2024" }
    end
  end

  private
    def margin(votes)
      100.0 * (votes.fetch(:dem_votes) - votes.fetch(:rep_votes)) / votes.fetch(:total_votes)
    end

    def read_votes(file)
      path = @directory.join(file)
      source = @manifest.fetch("sources").fetch(file)
      raise Invalid, "Checksum mismatch: #{file}" unless Digest::SHA256.file(path).hexdigest == source.fetch("sha256")

      rows = {}
      CSV.foreach(path, headers: true) do |row|
        key = [ row.fetch("state"), Integer(row.fetch("district"), 10) ]
        raise Invalid, "Duplicate district #{key.join('-')} in #{file}" if rows.key?(key)

        votes = %w[dem_votes rep_votes total_votes].to_h { |field| [ field.to_sym, Integer(row.fetch(field), 10) ] }
        unless votes.values.all? { |n| n >= 0 } && votes[:total_votes].positive? && votes[:dem_votes] + votes[:rep_votes] <= votes[:total_votes]
          raise Invalid, "Invalid votes for #{key.join('-')} in #{file}"
        end
        rows[key.freeze] = votes.freeze
      end
      rows.freeze
    rescue ArgumentError, KeyError => error
      raise Invalid, "#{file}: #{error.message}"
    end

    def validate!
      @manifest.fetch("plans").each do |state, plan|
        unless SEATS.key?(state) && plan.fetch("status") == "operative" && plan.fetch("id").present?
          raise Invalid, "Invalid operative plan for #{state}"
        end
        Date.iso8601(plan.fetch("adopted_on"))
      rescue Date::Error
        raise Invalid, "Invalid adoption date for #{state}"
      end
      expected = SEATS.flat_map { |state, count| (1..count).map { |district| [ state, district ] } }.sort
      unless @current.keys.sort == expected && @old.keys.sort == expected
        raise Invalid, "Each source must cover all 435 districts, with the correct state counts"
      end
      audit_path = @directory.join(@manifest.fetch("boundary_audit").fetch("file"))
      unless Digest::SHA256.file(audit_path).hexdigest == @manifest.fetch("boundary_audit").fetch("sha256")
        raise Invalid, "Boundary audit checksum mismatch"
      end
      audit = CSV.read(audit_path, headers: true)
      keys = audit.map { |row| [ row.fetch("state_fips"), row.fetch("district") ] }
      unless audit.size == 435 && keys.uniq.size == 435
        raise Invalid, "Boundary audit must cover 435 unique districts"
      end
      differences = audit.select { |row| row.fetch("changed") == "true" }.map do |row|
        [ CHANGED_STATE_FIPS.fetch(row.fetch("state_fips")), Integer(row.fetch("district"), 10) ]
      end
      raise Invalid, "Changed districts disagree with Census block assignments" unless differences.sort == @changed.sort
      raise Invalid, "Duplicate changed district" unless @changed.uniq.size == @changed.size
    end
end
