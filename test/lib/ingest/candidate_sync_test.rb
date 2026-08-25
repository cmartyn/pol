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
end
