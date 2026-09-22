module Ingest
  # Fetches every boundary the site's maps draw — one shoreline-clipped
  # outline per state, and every congressional district on the lines in
  # effect for the cycle — from the Census Bureau's TIGERweb API, and replaces
  # the boundaries table with them in one transaction.
  #
  # Like SeedRaces it refuses to half-succeed: a missing outline, or any
  # district count that disagrees with the race board, raises
  # IncompleteSource before anything is written, and the previous set stays.
  #
  # Nothing about the source is written down that the source can tell us:
  # layers are found by name, the Congress number comes from the cycle, and
  # FIPS codes are mapped to postal codes by the state layer's own fields.
  class BoundarySync
    IncompleteSource = Class.new(StandardError)

    # Cartographic boundaries: generalized and clipped to the shoreline,
    # unlike the legal TIGER lines, which run out into the Great Lakes.
    STATE_SERVICE = "Generalized_ACS2025/State_County".freeze
    STATE_LAYER = "States 500K".freeze
    # Legal district lines, which do extend into water; the maps clip them to
    # the state outline when drawing.
    DISTRICT_SERVICE = "TIGERweb/Legislative".freeze

    # The survey pass only needs each state's codes and extent.
    SURVEY_OFFSET = 0.05
    # Per-state detail: longitude span / DETAIL_STEPS, so a small state is
    # fetched finer than a large one and both land near half a pixel on a
    # 600 px state map.
    DETAIL_STEPS = 2000.0

    AT_LARGE_CODE = "00".freeze
    DELEGATE_CODE = "98".freeze
    DISTRICT_CODE = /\A\d\d\z/
    FIPS_CODE = /\A\d\d\z/

    Summary = Struct.new(:outlines, :districts, :points, keyword_init: true)

    # The Congress elected in a cycle's November: 2026 elects the 120th.
    def self.congress_for(cycle)
      ((cycle - 1788) / 2) + 1
    end

    # "00" is an at-large seat, which this app numbers 1; "01".."53" are
    # themselves. Delegates ("98") and water-only pieces ("ZZ") have no race
    # and come back nil.
    def self.district_number(code)
      return HouseCandidatesParser::AT_LARGE_DISTRICT if code == AT_LARGE_CODE
      return nil unless code.to_s.match?(DISTRICT_CODE) && code != DELEGATE_CODE

      code.to_i
    end

    # No U.S. state reaches east of the prime meridian, so a positive
    # longitude is an Aleutian island west of 180° and becomes lon − 360.
    def self.normalize(geometry)
      { "type" => geometry.fetch("type"), "coordinates" => normalize_positions(geometry.fetch("coordinates")) }
    end

    def self.normalize_positions(node)
      if node.first.is_a?(Numeric)
        lon, lat = node
        [ (lon.positive? ? lon - 360 : lon).round(5), lat.round(5) ]
      else
        node.map { |child| normalize_positions(child) }
      end
    end

    def self.positions(geometry)
      geometry.fetch("coordinates").flatten.each_slice(2)
    end

    def initialize(client: TigerwebClient.new, logger: Rails.logger, cycle: Sources.cycle,
                   states: Race::STATE_NAMES.keys, expected_districts: SeedRaces::HOUSE_DISTRICTS)
      @client = client
      @logger = logger
      @congress = self.class.congress_for(cycle)
      @states = states
      @expected_districts = expected_districts
    end

    def call
      outline_layer = @client.layer_id(STATE_SERVICE, STATE_LAYER)
      district_layer = @client.layer_id(DISTRICT_SERVICE, district_layer_name)

      rows = survey(outline_layer).flat_map do |state, info|
        offset = info.fetch(:lon_span) / DETAIL_STEPS
        @logger.info("[boundaries] #{state}: detail #{format("%.5f", offset)}°")
        [ outline_row(outline_layer, state, info.fetch(:fips), offset) ] +
          district_rows(district_layer, state, info.fetch(:fips), offset)
      end

      check_counts!(rows)
      write!(rows)
    end

    private
      def district_layer_name
        "#{@congress.ordinalize} Congressional Districts"
      end

      def district_field
        "CD#{@congress}"
      end

      # { "RI" => { fips: "44", lon_span: 0.8 }, ... } for every expected state.
      def survey(layer)
        _url, features = @client.features(STATE_SERVICE, layer, where: "1=1", out_fields: %w[STATE STUSAB], max_allowable_offset: SURVEY_OFFSET)
        found = features.each_with_object({}) do |feature, index|
          postal = feature.dig("properties", "STUSAB")
          fips = feature.dig("properties", "STATE").to_s
          next unless @states.include?(postal) && feature["geometry"] && fips.match?(FIPS_CODE)

          longitudes = self.class.positions(self.class.normalize(feature["geometry"])).map(&:first)
          index[postal] = { fips: fips, lon_span: longitudes.max - longitudes.min }
        end

        missing = @states - found.keys
        raise IncompleteSource, "#{STATE_LAYER} has no outline for #{missing.sort.join(", ")}" if missing.any?

        found.sort.to_h
      end

      def outline_row(layer, state, fips, offset)
        url, features = @client.features(STATE_SERVICE, layer, where: "STATE='#{fips}'", out_fields: %w[STATE STUSAB], max_allowable_offset: offset)
        feature = features.find { |candidate| candidate["geometry"] }
        raise IncompleteSource, "#{STATE_LAYER} returned no outline for #{state}" unless feature

        { state: state, district: nil, geometry: self.class.normalize(feature["geometry"]), source_url: url }
      end

      def district_rows(layer, state, fips, offset)
        url, features = @client.features(DISTRICT_SERVICE, layer, where: "STATE='#{fips}'", out_fields: [ "STATE", district_field ], max_allowable_offset: offset)
        features.filter_map do |feature|
          number = self.class.district_number(feature.dig("properties", district_field))
          next unless number && feature["geometry"]

          { state: state, district: number, geometry: self.class.normalize(feature["geometry"]), source_url: url }
        end
      end

      def check_counts!(rows)
        districts = rows.select { |row| row[:district] }
        found = districts.group_by { |row| row[:state] }.transform_values(&:size)
        expected = Race.house.where(state: @states).group(:state).count
        mismatches = (found.keys | expected.keys).sort.filter_map do |state|
          got = found.fetch(state, 0)
          want = expected.fetch(state, 0)
          "#{state} #{got} (races: #{want})" unless got == want
        end

        problems = []
        problems << "expected #{@expected_districts} districts, got #{districts.size}" unless districts.size == @expected_districts
        problems << "duplicate districts" unless districts.map { |row| row.values_at(:state, :district) }.uniq.size == districts.size
        problems << "district counts disagree with the race board: #{mismatches.join(", ")}" if mismatches.any?
        raise IncompleteSource, "#{district_layer_name}: #{problems.join("; ")}" if problems.any?
      end

      def write!(rows)
        Boundary.transaction do
          Boundary.delete_all
          Boundary.insert_all!(rows)
        end

        Summary.new(
          outlines: rows.count { |row| row[:district].nil? },
          districts: rows.count { |row| row[:district] },
          points: rows.sum { |row| self.class.positions(row[:geometry]).count }
        )
      end
  end
end
