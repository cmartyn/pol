# Standard normal draws from a seeded Random, by Box–Muller. No gem: the
# transform is four lines and the point of the exercise is that a run is
# reproducible from `model_runs.rng_seed` alone.
#
# Box–Muller produces two independent normals per pair of uniforms, so the
# second is kept and handed out on the next call. That halves the transcendental
# work across a run of several million draws, and the sequence stays a pure
# function of the seed and the order of calls.
class Forecast::Gaussian
  def initialize(random)
    @random = random
    @spare = nil
  end

  def next
    if @spare
      value = @spare
      @spare = nil
      return value
    end

    # Random#rand is [0, 1); log(0) is not a number we can use. The guard fires
    # about once every 9 quadrillion draws.
    first = @random.rand
    first = Float::MIN if first.zero?
    second = @random.rand

    radius = Math.sqrt(-2.0 * Math.log(first))
    angle = 2.0 * Math::PI * second
    @spare = radius * Math.sin(angle)
    radius * Math.cos(angle)
  end
end
