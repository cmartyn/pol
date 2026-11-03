require_relative "../pol/census_divisions"

module ElectionNight
  # A joint Gaussian update, followed by seat counting in the same sampled
  # worlds. Measurements are estimates of FINAL side-A-minus-B margin, not
  # the unadjusted margin in whatever ballots happened to report first.
  #
  # Only shared factors (at most 110, including reporting bias) need a dense matrix. Race-specific errors
  # can be integrated out for conditioning, then sampled conditionally on the
  # shared factors. This avoids a 470-by-470 factorization on every update.
  class Nowcast
    VERSION = "gaussian-returns-v2".freeze
    CAUCUSES = %w[dem rep uncommitted].freeze
    PARTIES = %w[dem rep other].freeze
    PERCENTILES = [ 5, 25, 50, 75, 95 ].freeze

    def initialize(prior:, observations:, seed: 5352026, n_sims: 10_000)
      @prior = stringify(prior)
      @observations = stringify(observations)
      @seed = Integer(seed)
      @n_sims = Integer(n_sims)
      raise ArgumentError, "n_sims must be between 1 and 1000000" unless (1..1_000_000).cover?(@n_sims)

      validate!
      prepare_factors
    end

    def call
      posterior = condition_shared_factors
      gaussian = Gaussian.new(Random.new(@seed))
      margins = @races.to_h { |race| [ race.fetch("race_key"), [] ] }
      wins = @races.to_h { |race| [ race.fetch("race_key"), Hash.new(0) ] }
      histograms = { "house" => Hash.new(0), "senate" => Hash.new(0) }
      controls = { "house" => Hash.new(0), "senate" => Hash.new(0) }

      @n_sims.times do
        factors = shared_draw(posterior, gaussian)
        tally = { "house" => CAUCUSES.to_h { |c| [ c, 0 ] },
                  "senate" => { "dem" => @holdover_dem, "rep" => @holdover_rep, "uncommitted" => 0 } }

        @races.each do |race|
          key = race.fetch("race_key")
          margin = conditional_margin(race, factors, gaussian)
          winner = race["certain"] || race.fetch(margin >= 0 ? "side_a" : "side_b")
          margins.fetch(key) << margin
          wins.fetch(key)[party(winner)] += 1
          tally.fetch(race.fetch("chamber"))[winner.fetch("caucus")] += 1
        end

        tally.each do |chamber, seats|
          histograms.fetch(chamber)[seats.fetch("dem")] += 1
          controls.fetch(chamber)["dem"] += 1 if seats.fetch("dem") >= @thresholds.fetch(chamber).fetch("dem")
          controls.fetch(chamber)["rep"] += 1 if seats.fetch("rep") >= @thresholds.fetch(chamber).fetch("rep")
        end
      end

      {
        "model_version" => VERSION, "seed" => @seed, "n_sims" => @n_sims,
        "chambers" => histograms.to_h { |chamber, histogram| [ chamber, chamber_output(histogram, controls.fetch(chamber)) ] },
        "races" => @races.map { |race| race_output(race, margins.fetch(race.fetch("race_key")), wins.fetch(race.fetch("race_key")), posterior) },
        "diagnostics" => {
          "observed_races" => @observations.size,
          "unobserved_races" => @races.size - @observations.size,
          "shared_factor_count" => @factor_names.size,
          "shared_effects" => @factor_names.each_with_index.to_h { |name, i| [ name, posterior.fetch(:mean)[i] * @factor_scales[i] ] },
          "observation_sigma_floor" => @sigma_floor,
          "observation_sigma_inflation" => @sigma_inflation,
          "sigma_reporting_bias" => @sigma_reporting_bias,
          "experimental" => true,
          "assumptions" => [
            "Measurements estimate final margins after adjusting for the geography that has reported.",
            "A state-specific reporting-bias factor affects observed margins but not final margins; remaining measurement errors are conditionally independent.",
            "Counted fractions describe estimated coverage and do not convert precinct reporting into ballots counted.",
            "No return measurement is treated as a race call; Gaussian tails and uncertainty remain.",
            "Parameters have not been calibrated against historical election-night reporting sequences."
          ]
        }
      }
    end

    private
      def stringify(value)
        case value
        when Hash then value.to_h { |key, item| [ key.to_s, stringify(item) ] }
        when Array then value.map { |item| stringify(item) }
        when Symbol then value.to_s
        else value
        end
      end

      def number(value, name, minimum: nil, maximum: nil)
        result = Float(value)
        raise ArgumentError, "#{name} must be finite" unless result.finite?
        raise ArgumentError, "#{name} must be >= #{minimum}" if minimum && result < minimum
        raise ArgumentError, "#{name} must be <= #{maximum}" if maximum && result > maximum
        result
      rescue TypeError
        raise ArgumentError, "#{name} must be numeric"
      end

      def integer(value, name, minimum: 0)
        numeric = number(value, name, minimum: minimum)
        raise ArgumentError, "#{name} must be an integer" unless numeric == numeric.to_i
        numeric.to_i
      end

      def validate!
        @races = @prior.fetch("races").sort_by { |race| race.fetch("race_key") }
        raise ArgumentError, "at least one race is required" if @races.empty?
        keys = @races.map { |race| race.fetch("race_key") }
        raise ArgumentError, "race keys must be unique" unless keys.uniq.size == keys.size
        @races.each do |race|
          raise ArgumentError, "race key must be present" unless race.fetch("race_key").is_a?(String) && !race.fetch("race_key").empty?
          raise ArgumentError, "unsupported chamber" unless %w[house senate].include?(race.fetch("chamber"))
          Pol::CensusDivisions.for(race.fetch("state"))
          race["mu"] = number(race.fetch("mu"), "mu", minimum: -100, maximum: 100)
          race["sigma"] = number(race.fetch("sigma"), "sigma", minimum: 0)
          [ race.fetch("side_a"), race.fetch("side_b"), race["certain"] ].compact.each do |side|
            raise ArgumentError, "side party must be present" if side.fetch("party").to_s.empty?
            raise ArgumentError, "unsupported caucus" unless CAUCUSES.include?(side.fetch("caucus"))
          end
        end

        @sigma_floor = number(@prior.fetch("observation_sigma_floor", 2.0), "observation_sigma_floor", minimum: 1)
        @sigma_inflation = number(@prior.fetch("observation_sigma_inflation", 1.5), "observation_sigma_inflation", minimum: 1)
        @sigma_reporting_bias = number(@prior.fetch("sigma_reporting_bias", 4.0), "sigma_reporting_bias", minimum: 0)
        @observations.sort_by! { |observation| observation.fetch("race_key") }
        @by_key = @races.to_h { |race| [ race.fetch("race_key"), race ] }
        observation_keys = @observations.map { |observation| observation.fetch("race_key") }
        raise ArgumentError, "aggregate duplicate race observations before conditioning" unless observation_keys.uniq.size == observation_keys.size
        @observations.each do |observation|
          key = observation.fetch("race_key")
          raise ArgumentError, "observation references unknown race #{key}" unless @by_key.key?(key)
          raise ArgumentError, "uncontested race cannot supply a return measurement" if @by_key.fetch(key)["certain"]
          observation["observed_margin"] = number(observation.fetch("observed_margin"), "observed_margin", minimum: -100, maximum: 100)
          observation["counted_fraction"] = number(observation.fetch("counted_fraction"), "counted_fraction", minimum: 0, maximum: 1)
          raise ArgumentError, "zero coverage cannot supply a return measurement" if observation.fetch("counted_fraction").zero?
          supplied_sigma = number(observation.fetch("sigma"), "observation sigma", minimum: 0)
          observation["effective_sigma"] = [ supplied_sigma * @sigma_inflation, @sigma_floor ].max
          observation["source_ids"] = Array(observation["source_ids"]).map(&:to_s).uniq.sort
        end
        @observation_by_key = @observations.to_h { |o| [ o.fetch("race_key"), o ] }
        @holdover_dem = integer(@prior.fetch("senate_dem_holdover", 34), "senate_dem_holdover")
        @holdover_rep = integer(@prior.fetch("senate_rep_holdover", 31), "senate_rep_holdover")
        @thresholds = {
          "house" => { "dem" => integer(@prior.fetch("house_majority", 218), "house_majority", minimum: 1),
                       "rep" => integer(@prior.fetch("house_majority", 218), "house_majority", minimum: 1) },
          "senate" => { "dem" => integer(@prior.fetch("senate_dem_threshold", 51), "senate_dem_threshold", minimum: 1),
                        "rep" => integer(@prior.fetch("senate_rep_threshold", 50), "senate_rep_threshold", minimum: 1) }
        }
      end

      def prepare_factors
        scales = {
          "national" => number(@prior.fetch("sigma_national"), "sigma_national", minimum: 0),
          "division" => number(@prior.fetch("sigma_regional", 0), "sigma_regional", minimum: 0),
          "state" => number(@prior.fetch("sigma_state"), "sigma_state", minimum: 0),
          "reporting_bias" => @sigma_reporting_bias
        }
        names = [ "national" ]
        names.concat(@races.map { |race| "division:#{Pol::CensusDivisions.for(race.fetch('state'))}" }.uniq.sort)
        names.concat(@races.map { |race| "state:#{race.fetch('state')}" }.uniq.sort)
        names.concat(@observations.map { |observation| "reporting_bias:#{@by_key.fetch(observation.fetch('race_key')).fetch('state')}" }.uniq.sort)
        @factor_names = names.select { |name| scales.fetch(name.split(":").first).positive? }
        @factor_scales = @factor_names.map { |name| scales.fetch(name.split(":").first) }
        indices = @factor_names.each_with_index.to_h
        @loadings = @races.to_h do |race|
          applicable = [ "national", "division:#{Pol::CensusDivisions.for(race.fetch('state'))}", "state:#{race.fetch('state')}" ]
          [ race.fetch("race_key"), applicable.filter_map { |name| [ indices.fetch(name), scales.fetch(name.split(":").first) ] if indices.key?(name) } ]
        end
        @bias_loadings = @races.to_h do |race|
          name = "reporting_bias:#{race.fetch('state')}"
          [ race.fetch("race_key"), indices.key?(name) ? [ [ indices.fetch(name), @sigma_reporting_bias ] ] : [] ]
        end
        @measurement_loadings = @loadings.to_h { |key, loading| [ key, loading + @bias_loadings.fetch(key) ] }
      end

      # Shared factors z have N(0,I) priors. Measurement loadings include the
      # reporting-bias factor, while final-margin loadings omit it.
      # Integrating out the race error
      # gives measurement variance sigma_race² + sigma_measurement². Hence
      # posterior precision I + sum(aa'/v), and information sum(a*(y-mu)/v).
      def condition_shared_factors
        size = @factor_names.size
        precision = Array.new(size) { |i| Array.new(size) { |j| i == j ? 1.0 : 0.0 } }
        information = Array.new(size, 0.0)
        @observations.each do |observation|
          race = @by_key.fetch(observation.fetch("race_key"))
          variance = race.fetch("sigma")**2 + observation.fetch("effective_sigma")**2
          loading = @measurement_loadings.fetch(race.fetch("race_key"))
          residual = observation.fetch("observed_margin") - race.fetch("mu")
          loading.each do |i, coefficient|
            information[i] += coefficient * residual / variance
            loading.each { |j, other| precision[i][j] += coefficient * other / variance }
          end
        end
        factor = cholesky(precision)
        mean = backsolve(factor, forwardsolve(factor, information))
        { mean: mean, factor: factor, precision: precision }
      end

      def cholesky(matrix)
        size = matrix.size
        lower = Array.new(size) { Array.new(size, 0.0) }
        size.times do |i|
          (0..i).each do |j|
            value = matrix[i][j]
            j.times { |k| value -= lower[i][k] * lower[j][k] }
            lower[i][j] = if i == j
              raise ArgumentError, "non-positive posterior precision" unless value.positive?
              Math.sqrt(value)
            else
              value / lower[j][j]
            end
          end
        end
        lower
      end

      def forwardsolve(lower, vector)
        result = Array.new(vector.size, 0.0)
        vector.size.times do |i|
          value = vector[i]
          i.times { |j| value -= lower[i][j] * result[j] }
          result[i] = value / lower[i][i]
        end
        result
      end

      # Solve L' x = b. If P=L L', L'^(-1) z has covariance P^(-1).
      def backsolve(lower, vector)
        result = Array.new(vector.size, 0.0)
        (vector.size - 1).downto(0) do |i|
          value = vector[i]
          ((i + 1)...vector.size).each { |j| value -= lower[j][i] * result[j] }
          result[i] = value / lower[i][i]
        end
        result
      end

      def shared_draw(posterior, gaussian)
        noise = Array.new(@factor_names.size) { gaussian.next }
        noise = backsolve(posterior.fetch(:factor), noise) unless @observations.empty?
        noise.each_index.map { |i| posterior.fetch(:mean)[i] + noise[i] }
      end

      def conditional_margin(race, factors, gaussian)
        return race.fetch("mu") if race["certain"]

        center = race.fetch("mu") + @loadings.fetch(race.fetch("race_key")).sum { |i, scale| factors[i] * scale }
        own_variance = race.fetch("sigma")**2
        if (observation = @observation_by_key[race.fetch("race_key")])
          noise_variance = observation.fetch("effective_sigma")**2
          gain = own_variance / (own_variance + noise_variance)
          reporting_bias = @bias_loadings.fetch(race.fetch("race_key")).sum { |i, scale| factors[i] * scale }
          center += gain * (observation.fetch("observed_margin") - center - reporting_bias)
          own_variance *= 1.0 - gain
        end
        center + gaussian.next * Math.sqrt(own_variance)
      end

      def party(side)
        PARTIES.include?(side.fetch("party")) ? side.fetch("party") : "other"
      end

      def race_output(race, margins, wins, posterior)
        margins.sort!
        observation = @observation_by_key[race.fetch("race_key")]
        # Analytic mean avoids showing simulation noise as a change in margin.
        mean = race.fetch("mu")
        unless race["certain"]
          mean += @loadings.fetch(race.fetch("race_key")).sum { |i, scale| posterior.fetch(:mean)[i] * scale }
          if observation
            gain = race.fetch("sigma")**2 / (race.fetch("sigma")**2 + observation.fetch("effective_sigma")**2)
            reporting_bias = @bias_loadings.fetch(race.fetch("race_key")).sum { |i, scale| posterior.fetch(:mean)[i] * scale }
            mean += gain * (observation.fetch("observed_margin") - mean - reporting_bias)
          end
        end
        status = if race["certain"] then "uncontested"
        elsif observation then "returns_updated"
        elsif @observations.any? then "shared_update"
        else "prior_only"
        end
        {
          "race_key" => race.fetch("race_key"), "state" => race.fetch("state"), "chamber" => race.fetch("chamber"),
          "p_dem_win" => wins["dem"].to_f / @n_sims, "p_rep_win" => wins["rep"].to_f / @n_sims,
          "p_other_win" => wins["other"].to_f / @n_sims, "mean_margin" => mean,
          "percentiles" => PERCENTILES.to_h { |p| [ p.to_s, margins[((p / 100.0 * @n_sims).ceil - 1).clamp(0, @n_sims - 1)] ] },
          "status" => status, "direct_observation" => !observation.nil?,
          "counted_fraction" => observation && observation.fetch("counted_fraction"),
          "measurement_sigma" => observation && observation.fetch("effective_sigma"),
          "source_ids" => observation ? observation.fetch("source_ids") : []
        }
      end

      def chamber_output(histogram, controls)
        p_dem = controls["dem"].to_f / @n_sims
        p_rep = controls["rep"].to_f / @n_sims
        {
          "p_dem_control" => p_dem, "p_rep_control" => p_rep,
          "p_unresolved_control" => [ 1.0 - p_dem - p_rep, 0.0 ].max,
          "mean_dem_seats" => histogram.sum { |seats, count| seats * count }.to_f / @n_sims,
          "seat_histogram" => histogram.sort.to_h.transform_keys(&:to_s)
        }
      end

      class Gaussian
        def initialize(random)
          @random = random
        end

        def next
          if @spare
            value, @spare = @spare, nil
            return value
          end
          radius = Math.sqrt(-2.0 * Math.log([ @random.rand, Float::MIN ].max))
          angle = 2.0 * Math::PI * @random.rand
          @spare = radius * Math.sin(angle)
          radius * Math.cos(angle)
        end
      end
  end
end
