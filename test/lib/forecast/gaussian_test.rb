require "test_helper"

class Forecast::GaussianTest < ActiveSupport::TestCase
  test "the same seed produces the same sequence" do
    first = Array.new(20) { Forecast::Gaussian.new(Random.new(1234)).next }
    second = Array.new(20) { Forecast::Gaussian.new(Random.new(1234)).next }

    assert_equal first, second
    refute_equal first.first, Forecast::Gaussian.new(Random.new(1235)).next
  end

  # The transform, worked out independently of the class: two uniforms in, two
  # normals out, the second held back for the following call.
  test "the pair is Box-Muller on the underlying generator" do
    reference = Random.new(42)
    first_uniform = reference.rand
    second_uniform = reference.rand
    radius = Math.sqrt(-2.0 * Math.log(first_uniform))
    angle = 2.0 * Math::PI * second_uniform

    gaussian = Forecast::Gaussian.new(Random.new(42))

    assert_in_delta radius * Math.cos(angle), gaussian.next, 1e-12
    assert_in_delta radius * Math.sin(angle), gaussian.next, 1e-12
  end

  test "the draws are standard normal" do
    gaussian = Forecast::Gaussian.new(Random.new(7))
    draws = Array.new(200_000) { gaussian.next }
    mean = draws.sum / draws.size
    standard_deviation = Math.sqrt(draws.sum { |draw| (draw - mean)**2 } / draws.size)

    assert_in_delta 0.0, mean, 0.02
    assert_in_delta 1.0, standard_deviation, 0.02
    # Two-thirds inside one sigma, 95% inside two.
    assert_in_delta 0.6827, draws.count { |draw| draw.abs <= 1 }.to_f / draws.size, 0.01
    assert_in_delta 0.9545, draws.count { |draw| draw.abs <= 2 }.to_f / draws.size, 0.01
  end
end
