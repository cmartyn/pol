require "test_helper"

class ElectionNight::PreElectionSnapshotTest < ActiveSupport::TestCase
  test "frozen run preserves persisted published values rather than simulating or using newer variants" do
    pinned = model_runs(:model_run_one)
    newer = copy_run(finished_at: ElectionNight::Prior::POLL_CLOSE_CUTOFF - 60)
    newer.chamber_forecasts.excl_internals.find_by!(chamber: :house).update!(p_dem_control: 0.99, p_rep_control: 0.01)
    alternate = chamber_forecasts(:house_chamber_forecast).dup
    alternate.assign_attributes(variant: :incl_internals, p_dem_control: 0.88, p_rep_control: 0.12)
    alternate.save!
    alternate_race = forecasts(:maine_forecast).dup
    alternate_race.assign_attributes(variant: :incl_internals, p_dem_win: 0.77, p_rep_win: 0.23)
    alternate_race.save!

    result = ElectionNight::PreElectionSnapshot.new(prior: { "model_run_id" => pinned.id, "as_of" => "wrong" }).call

    assert_equal pinned.id, result["prior_model_run_id"]
    assert_equal pinned.finished_at.iso8601, result["generated_at"]
    assert_equal pinned.finished_at.iso8601, result["prior_as_of"]
    assert_equal "pre_election", result["status"]
    assert_equal "pre_election_forecast", result["model_version"]
    %w[house senate].each do |chamber|
      record = pinned.chamber_forecasts.excl_internals.find_by!(chamber: chamber)
      assert_equal record.slice("p_dem_control", "p_rep_control", "mean_dem_seats", "seat_histogram"),
        result["chambers"][chamber].except("p_unresolved_control")
    end
    persisted = forecasts(:maine_forecast)
    assert_equal persisted.slice("p_dem_win", "p_rep_win", "p_other_win", "mean_margin"),
      result["races"].first.slice("p_dem_win", "p_rep_win", "p_other_win", "mean_margin")
    assert_equal persisted.margin_percentiles, result["races"].first["percentiles"]
    assert result.dig("diagnostics", "experimental")
    assert_equal 1, result.dig("coverage", "races_total")
    assert_equal 0, result.dig("coverage", "races_with_returns")
    assert_empty result["sources"]
    assert_empty result["input_hashes"]
  end

  test "unpinned fallback selects the latest succeeded pre-close run and excludes later completed runs" do
    eligible = copy_run(finished_at: ElectionNight::Prior::POLL_CLOSE_CUTOFF - 60)
    copy_run(finished_at: ElectionNight::Prior::POLL_CLOSE_CUTOFF)
    copy_run(finished_at: ElectionNight::Prior::POLL_CLOSE_CUTOFF + 60)
    copy_run(finished_at: ElectionNight::Prior::POLL_CLOSE_CUTOFF - 10, status: :failed)

    result = ElectionNight::PreElectionSnapshot.new.call

    assert_equal eligible.id, result["prior_model_run_id"]
  end

  test "invalid pins never substitute a valid saved run" do
    late = copy_run(finished_at: ElectionNight::Prior::POLL_CLOSE_CUTOFF)
    failed = copy_run(finished_at: ElectionNight::Prior::POLL_CLOSE_CUTOFF - 60, status: :failed)
    missing = ModelRun.maximum(:id) + 100
    [ {}, { "model_run_id" => missing }, { "model_run_id" => late.id }, { "model_run_id" => failed.id },
      { "model_run_id" => "#{model_runs(:model_run_one).id}invalid" } ].each do |prior|
      assert_nil ElectionNight::PreElectionSnapshot.new(prior: prior).call, prior.inspect
    end
  end

  test "no pre-close succeeded run leaves the fallback unavailable" do
    ModelRun.update_all(finished_at: ElectionNight::Prior::POLL_CLOSE_CUTOFF + 60)

    assert_nil ElectionNight::PreElectionSnapshot.new.call
  end

  test "both published chamber records are required and invalid probabilities fail closed" do
    chamber = chamber_forecasts(:house_chamber_forecast)
    chamber.update!(variant: :incl_internals)
    assert_nil ElectionNight::PreElectionSnapshot.new.call
    chamber.update!(variant: :excl_internals, p_dem_control: Float::NAN)
    assert_nil ElectionNight::PreElectionSnapshot.new.call
    chamber.update!(p_dem_control: 1.01)
    assert_nil ElectionNight::PreElectionSnapshot.new.call
    chamber.update!(p_dem_control: 0.48)
    forecasts(:maine_forecast).update!(p_rep_win: Float::INFINITY)
    assert_nil ElectionNight::PreElectionSnapshot.new.call
  end

  test "unresolved control and independent race probabilities are preserved" do
    chamber_forecasts(:senate_chamber_forecast).update!(p_dem_control: 0.2, p_rep_control: 0.3)
    forecasts(:maine_forecast).update!(p_dem_win: 0.0, p_rep_win: 0.35, p_other_win: 0.65)

    result = ElectionNight::PreElectionSnapshot.new.call

    assert_equal 0.5, result.dig("chambers", "senate", "p_unresolved_control")
    assert_equal 0.65, result["races"].first["p_other_win"]
    assert_equal 0.0, result["races"].first["p_dem_win"]
  end

  test "raw votes remain unknown and canonical race keys match the frozen prior" do
    house = forecasts(:maine_forecast).dup
    house.race = races(:house_ny_17)
    house.save!
    at_large = Race.create!(office: :house, state: "AK", district: 1, cycle: 2026, slug: "house-ak-2026")
    copy = house.dup
    copy.race = at_large
    copy.save!

    result = ElectionNight::PreElectionSnapshot.new.call

    assert_equal %w[AK-AL ME-S NY-17], result["races"].map { |race| race["race_key"] }
    result["races"].each do |race|
      assert_nil race["observed_votes"]
      assert_equal false, race["has_raw_source"]
      assert_equal false, race["direct_observation"]
      assert_equal "prior_only", race["status"]
    end
  end

  test "sampled certainty is not called uncontested without consistent frozen metadata" do
    forecasts(:maine_forecast).update!(p_dem_win: 1.0, p_rep_win: 0.0)
    assert_equal "prior_only", ElectionNight::PreElectionSnapshot.new.call["races"].first["status"]
    prior = { "model_run_id" => model_runs(:model_run_one).id,
      "races" => [ { "race_key" => "ME-S", "certain" => { "party" => "dem" } } ] }
    assert_equal "uncontested", ElectionNight::PreElectionSnapshot.new(prior: prior).call["races"].first["status"]
    prior["races"].first["certain"]["party"] = "rep"
    assert_equal "prior_only", ElectionNight::PreElectionSnapshot.new(prior: prior).call["races"].first["status"]
  end

  private
    def copy_run(finished_at:, status: :succeeded)
      run = ModelRun.create!(started_at: finished_at - 30, finished_at: finished_at, status: status,
        trigger: :manual, params_snapshot: model_runs(:model_run_one).params_snapshot)
      model_runs(:model_run_one).chamber_forecasts.excl_internals.each do |record|
        copy = record.dup
        copy.model_run = run
        copy.save!
      end
      copy = forecasts(:maine_forecast).dup
      copy.model_run = run
      copy.save!
      run
    end
end
