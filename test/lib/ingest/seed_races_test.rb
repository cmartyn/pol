require "test_helper"

class Ingest::SeedRacesTest < ActiveSupport::TestCase
  setup do
    stub_wikipedia_page(Ingest::Sources::HOUSE_RESULTS_TITLE, fixture: "house_results_2024.html")
    stub_wikipedia_page(Ingest::Sources::PRESIDENTIAL_TITLES.fetch(2024), fixture: "presidential_2024.html")
    stub_wikipedia_page(Ingest::Sources::PRESIDENTIAL_TITLES.fetch(2020), fixture: "presidential_2020.html")
  end

  def seed
    Ingest::SeedRaces.new.call
  end

  test "seeds every Senate race on the verified list, specials included" do
    summary = seed

    assert_equal 35, summary.senate
    assert_equal 2, summary.specials
    assert_equal 35, Race.senate.where(cycle: 2026, slug: Race.where("slug LIKE ?", "senate-2026-%").select(:slug)).count
    assert Race.exists?(slug: "senate-2026-fl-special", special: true)
    assert Race.exists?(slug: "senate-2026-oh-special", special: true)
  end

  test "a Senate race carries its incumbent, seat class and open-seat status" do
    seed
    georgia = Race.find_by!(slug: "senate-2026-ga")
    kentucky = Race.find_by!(slug: "senate-2026-ky")

    assert_equal "senate", georgia.office
    assert_equal 2, georgia.seat_class
    assert_equal "Jon Ossoff", georgia.incumbent_name
    assert_equal "dem", georgia.incumbent_party
    assert_not georgia.open_seat

    assert_equal "Mitch McConnell", kentucky.incumbent_name
    assert kentucky.open_seat, "McConnell is retiring, so the seat is open"
  end

  test "candidates come with their party and incumbency" do
    seed
    georgia = Race.find_by!(slug: "senate-2026-ga")

    assert_equal [ "Jon Ossoff", "Mike Collins" ], georgia.candidates.order(:id).map(&:name)
    assert_equal %w[dem rep], georgia.candidates.order(:id).map(&:party)
    assert_equal [ true, false ], georgia.candidates.order(:id).map(&:incumbent)
  end

  test "races whose primary has not happened yet get only the candidates we can source" do
    seed

    assert_empty Race.find_by!(slug: "senate-2026-mn").candidates
    assert_equal [ "Annie Andrews" ], Race.find_by!(slug: "senate-2026-sc").candidates.map(&:name)
  end

  test "Senate lean is the mean of each year's state margin minus the national margin" do
    seed
    georgia = Race.find_by!(slug: "senate-2026-ga")

    # 2024: −2.19 − (−1.5) = −0.69; 2020: 0.23 − 4.5 = −4.27; mean −2.48.
    assert_in_delta(-2.48, georgia.lean, 0.01)
    assert_equal 35, seed.leans
  end

  test "House districts get their 2024 margin and the page it came from" do
    summary = seed
    district = Race.find_by!(slug: "house-2026-al-01")

    assert_equal 24, summary.house, "the fixture carries four states' worth of districts"
    assert_equal "house", district.office
    assert_equal 1, district.district
    assert_in_delta(-57.0, district.baseline_margin)
    assert_not district.baseline_imputed
    assert_equal Ingest::WikipediaClient.article_url(Ingest::Sources::HOUSE_RESULTS_TITLE), district.baseline_source_url
  end

  test "a district with no major-party opponent gets the documented imputed margin, signed toward the winner" do
    summary = seed
    imputed = Pol::Params.fetch!(:fundamentals, :imputed_baseline_margin)

    assert_includes summary.imputed_districts, "AL-3"
    assert_includes summary.imputed_districts, "WA-9"
    assert_in_delta(-imputed, Race.find_by!(slug: "house-2026-al-03").baseline_margin)
    assert Race.find_by!(slug: "house-2026-al-03").baseline_imputed
    assert_in_delta imputed, Race.find_by!(slug: "house-2026-wa-09").baseline_margin
  end

  # The fixture deliberately holds the four most awkward states, so its
  # imputation rate (6 of 24) is far above the real page's. The rate across all
  # 435 districts is recorded in docs/BUILD_NOTES.md from the live run; what
  # this pins down is *which* districts get imputed and that nothing else does.
  test "only the districts a major party skipped are imputed" do
    summary = seed

    assert_equal %w[AL-3 AL-4 AL-5 LA-4 WA-4 WA-9], summary.imputed_districts.sort
    assert_equal summary.imputed, Race.house.where(baseline_imputed: true).count
  end

  test "re-running changes nothing and duplicates nothing" do
    seed
    counts = [ Race.count, Candidate.count ]

    summary = seed

    assert_equal counts, [ Race.count, Candidate.count ]
    assert_equal 35, summary.senate
    assert_empty summary.warnings
  end

  test "a candidate dropped from the verified list is removed, unless a poll points at them" do
    seed
    georgia = Race.find_by!(slug: "senate-2026-ga")
    dropped = georgia.candidates.create!(name: "Withdrawn Hopeful", party: :rep)
    cited = georgia.candidates.create!(name: "Cited Hopeful", party: :rep)
    polls(:maine_poll_one).poll_results.create!(party: :rep, pct: 12.0, candidate: cited)

    summary = seed

    assert_not Candidate.exists?(dropped.id)
    assert Candidate.exists?(cited.id)
    assert_match(/Cited Hopeful/, summary.warnings.first)
  end
end
