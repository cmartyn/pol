require "test_helper"

class Ingest::CandidateSyncTest < ActiveSupport::TestCase
  test "upserts a candidate's party, caucus_with and incumbency" do
    race = races(:senate_maine)
    warnings = []
    # All three existing candidates stay on the list so the only thing under
    # test is the upsert — nothing here should trigger a prune.
    entries = [
      { "name" => "Jordan Ellis", "party" => "ind", "caucus_with" => "dem", "incumbent" => true },
      { "name" => "Pat Rivers", "party" => "rep", "incumbent" => true },
      { "name" => "Sam Winter", "party" => "ind", "caucus_with" => "dem" }
    ]

    Ingest::CandidateSync.apply(race, entries, warnings: warnings)

    ellis = race.candidates.find_by!(name: "Jordan Ellis")
    assert_equal "ind", ellis.party
    assert_equal "dem", ellis.caucus_with
    assert ellis.incumbent
    assert_empty warnings
  end

  test "incumbent defaults to false when the entry omits it" do
    race = races(:senate_maine)
    # Same guard as above: keep every existing candidate on the list so this
    # test exercises only the default, not a prune.
    entries = [
      { "name" => "Jordan Ellis", "party" => "dem" },
      { "name" => "Pat Rivers", "party" => "rep", "incumbent" => true },
      { "name" => "Sam Winter", "party" => "ind", "caucus_with" => "dem" },
      { "name" => "New Face", "party" => "dem" }
    ]

    Ingest::CandidateSync.apply(race, entries, warnings: [])

    assert_not race.candidates.find_by!(name: "New Face").incumbent
  end

  test "prunes a candidate no longer on the entry list when nothing polls-references them" do
    race = races(:senate_maine)
    # Fetch the fixture's id before the destroy — the fixture accessor
    # itself does a find(id), which would raise once the row is gone.
    stale_id = candidates(:maine_ind).id
    entries = [
      { "name" => "Jordan Ellis", "party" => "dem" },
      { "name" => "Pat Rivers", "party" => "rep", "incumbent" => true }
    ]

    Ingest::CandidateSync.apply(race, entries, warnings: [])

    assert_not Candidate.exists?(stale_id), "Sam Winter dropped off the list and has no poll results"
    assert Candidate.exists?(candidates(:maine_dem).id)
    assert Candidate.exists?(candidates(:maine_rep).id)
  end

  test "keeps a stale candidate referenced by poll results and appends the warning" do
    race = races(:senate_maine)
    entries = [
      { "name" => "Sam Winter", "party" => "ind", "caucus_with" => "dem" }
    ]
    warnings = [ "pre-existing warning" ]

    Ingest::CandidateSync.apply(race, entries, warnings: warnings)

    assert Candidate.exists?(candidates(:maine_dem).id), "Jordan Ellis is cited by poll results and must survive"
    assert Candidate.exists?(candidates(:maine_rep).id), "Pat Rivers is cited by poll results and must survive"
    assert_includes warnings, "pre-existing warning", "apply appends to the caller's array rather than replacing it"
    assert_includes warnings, "kept #{race.slug} candidate \"Jordan Ellis\": referenced by existing poll results"
    assert_includes warnings, "kept #{race.slug} candidate \"Pat Rivers\": referenced by existing poll results"
  end

  # ---------------------------------------------------------------------
  # prune: :listed_parties — the House daily sync's mode (Task 3 ruling 2).
  # A Wikipedia infobox names only the leading candidates per party, not the
  # whole ballot, so a wholesale prune would delete a hand-added minor
  # candidate the page never mentions. These are unit-tested directly here,
  # separately from the job that calls them, per the controller ruling.
  # ---------------------------------------------------------------------

  test "prune: :listed_parties leaves alone a stale candidate whose party is not among the entries" do
    race = Race.create!(office: :house, state: "VT", district: 1, cycle: 2026,
                         slug: "house-2026-vt-01", baseline_margin: 0.0)
    Ingest::CandidateSync.apply(
      race,
      [
        { "name" => "Dem Nominee", "party" => "dem" },
        { "name" => "Rep Nominee", "party" => "rep" },
        { "name" => "Indie Add", "party" => "ind" }
      ],
      warnings: []
    )

    Ingest::CandidateSync.apply(
      race,
      [
        { "name" => "Dem Nominee", "party" => "dem" },
        { "name" => "Rep Nominee", "party" => "rep" }
      ],
      warnings: [],
      prune: :listed_parties
    )

    assert_equal [ "Dem Nominee", "Indie Add", "Rep Nominee" ], race.candidates.reload.order(:name).map(&:name),
                 "the infobox never lists an independent, so ind is not a listed party this run"
  end

  test "prune: :listed_parties removes a same-party candidate replaced on the entry list" do
    race = Race.create!(office: :house, state: "VT", district: 1, cycle: 2026,
                         slug: "house-2026-vt-01", baseline_margin: 0.0)
    Ingest::CandidateSync.apply(
      race,
      [ { "name" => "Old Dem", "party" => "dem" }, { "name" => "GOP Nominee", "party" => "rep" } ],
      warnings: []
    )

    Ingest::CandidateSync.apply(
      race,
      [ { "name" => "New Dem", "party" => "dem" }, { "name" => "GOP Nominee", "party" => "rep" } ],
      warnings: [],
      prune: :listed_parties
    )

    assert_not race.candidates.exists?(name: "Old Dem"), "dem is a listed party, so a nominee dropped from it is stale"
    assert race.candidates.exists?(name: "New Dem")
    assert race.candidates.exists?(name: "GOP Nominee")
  end

  test "prune: :listed_parties still keeps a stale candidate referenced by poll results" do
    race = races(:senate_maine)
    warnings = []

    Ingest::CandidateSync.apply(
      race,
      [ { "name" => "New Face", "party" => "dem" }, { "name" => "Pat Rivers", "party" => "rep", "incumbent" => true } ],
      warnings: warnings,
      prune: :listed_parties
    )

    assert Candidate.exists?(candidates(:maine_dem).id), "Jordan Ellis is dem, a listed party, but polls still cite them"
    assert Candidate.exists?(candidates(:maine_ind).id), "ind is not a listed party this run"
    assert_includes warnings, "kept #{race.slug} candidate \"Jordan Ellis\": referenced by existing poll results"
  end
end
