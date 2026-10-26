require "test_helper"
require "tmpdir"

class Forecast::HouseBaselinesTest < ActiveSupport::TestCase
  test "the complete source covers 435 seats and all changed Census assignments" do
    audit = Forecast::HouseBaselines.current.audit
    assert_equal 435, audit.size
    counts = audit.select { |row| row[:changed] }.group_by { |row| row[:state] }.transform_values(&:size)
    assert_equal({ "AL" => 4, "CA" => 48, "FL" => 23, "LA" => 6, "NC" => 2,
                   "OH" => 13, "TN" => 8, "TX" => 37, "UT" => 4 }, counts)
    # A minor vote-data revision is not redistricting; identical vote counts
    # likewise do not prove identical territory.
    assert Forecast::HouseBaselines.current.changed?(district("CA", 11))
    assert Forecast::HouseBaselines.current.changed?(district("FL", 3))
    assert_not Forecast::HouseBaselines.current.changed?(district("CA", 34))
    assert_not Forecast::HouseBaselines.current.changed?(district("OH", 3))
    assert_not Forecast::HouseBaselines.current.changed?(district("MO", 5))
  end

  test "TN9 uses presidential votes on new lines and the presidential national reference" do
    race = district("TN", 9, baseline_margin: 45.6, open_seat: true, incumbent_party: :dem)
    model = model_for(race)
    assert_equal({ dem_votes: 124805, rep_votes: 192867, total_votes: 321897 }, model.house_baseline.votes)
    assert_in_delta(-21.1440305439, model.house_baseline.margin, 1e-9)
    assert_in_delta(-17.6440305439, model.prior, 1e-9) # -21.144 - (-1.5) + 2
    race.open_seat = false
    assert_in_delta model.prior, model_for(race).prior, 1e-9
    race.baseline_margin = -35.0 # what a legacy reseed or admin edit could do
    assert_in_delta model.prior, model_for(race).prior, 1e-9
  end

  test "new-line inputs cover shifts in both directions and unchanged seats retain House arithmetic" do
    assert_in_delta 23.6255, model_for(district("UT", 1)).house_baseline.margin, 0.001
    assert_in_delta(-19.7929, model_for(district("TX", 9)).house_baseline.margin, 0.001)
    race = district("NY", 17, baseline_margin: 2.7, open_seat: true, incumbent_party: :dem)
    assert_in_delta 5.8, model_for(race).prior, 1e-9
    assert_equal "house_result", model_for(district("AK", 1)).house_baseline.method
  end

  test "missing historical inputs and unsupported cycles never become zero priors" do
    assert_raises(Forecast::HouseBaselines::Invalid) { model_for(district("NY", 17, baseline_margin: nil)).prior }
    assert_raises(Forecast::HouseBaselines::Invalid) { model_for(district("TN", 9, cycle: 2028)).prior }
  end

  test "source edits and incomplete boards fail validation" do
    Dir.mktmpdir do |directory|
      FileUtils.cp_r(Dir[Forecast::HouseBaselines::DIRECTORY.join("*")], directory)
      File.open(File.join(directory, "presidential_2024.csv"), "a") { |file| file.puts "TN,9,1,2,3" }
      assert_raises(Forecast::HouseBaselines::Invalid) { Forecast::HouseBaselines.new(directory: directory) }
    end
    assert_raises(Forecast::HouseBaselines::Invalid) { Forecast::HouseBaselines.current.validate_board!([ races(:house_ny_17) ]) }
  end

  test "runner snapshots exact new-line inputs for both variants" do
    race = district("TN", 9)
    race.save!
    run = Forecast::Runner.call(trigger: :manual, as_of: Date.new(2026, 10, 25), seed: 20, n_sims: 100)
    saved = run.params_snapshot.dig("house_baselines", "races", race.id.to_s)
    assert_equal "presidential_lean", saved.fetch("method")
    assert_equal(-1.5, saved.fetch("national_margin"))
    assert_equal 321897, saved.dig("votes", "total_votes")
    assert_equal 2, run.forecasts.where(race: race).count
    race.update!(baseline_margin: -35)
    assert_equal saved, run.reload.params_snapshot.dig("house_baselines", "races", race.id.to_s)
  end

  test "partial and duplicate source snapshots are rejected even with updated checksums" do
    [ :partial, :duplicate ].each do |problem|
      Dir.mktmpdir do |directory|
        FileUtils.cp_r(Dir[Forecast::HouseBaselines::DIRECTORY.join("*")], directory)
        path = File.join(directory, "presidential_2024.csv")
        lines = File.readlines(path)
        problem == :partial ? lines.pop : lines.push(lines.last)
        File.write(path, lines.join)
        manifest_path = File.join(directory, "manifest.yml")
        manifest = YAML.safe_load_file(manifest_path)
        manifest["sources"]["presidential_2024.csv"]["sha256"] = Digest::SHA256.file(path).hexdigest
        File.write(manifest_path, YAML.dump(manifest))
        error = assert_raises(Forecast::HouseBaselines::Invalid) { Forecast::HouseBaselines.new(directory: directory) }
        assert_match(problem == :partial ? /435/ : /Duplicate/, error.message)
      end
    end
  end

  test "an invalid board records a failed run and leaves public forecasts alone" do
    prior = ModelRun.succeeded.latest.first
    run = Forecast::Runner.call(trigger: :manual, n_sims: 10, require_complete_house: true, raise_on_error: false)
    assert_predicate run, :failed?
    assert_match(/435/, run.error_message)
    assert_equal prior, ModelRun.succeeded.latest.first
    assert_empty run.forecasts
  end

  private
    def district(state, number, **attributes)
      Race.new(office: :house, state: state, district: number, cycle: 2026,
        baseline_margin: 0.0, slug: "house-2026-#{state.downcase}-#{number}", **attributes)
    end

    def model_for(race)
      Forecast::RaceModel.new(race: race, national_env: 2.0,
        averager: Forecast::Averager.new(as_of: Date.new(2026, 10, 25)), polls: [])
    end
end
