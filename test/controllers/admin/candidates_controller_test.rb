require "test_helper"

class Admin::CandidatesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "create adds a candidate to the race and redirects to the race's edit page" do
    assert_difference "races(:senate_maine).candidates.count", 1 do
      post admin_race_candidates_path(races(:senate_maine)),
           params: { candidate: { name: "New Candidate", party: "ind", incumbent: "0" } }
    end

    assert_redirected_to edit_admin_race_path(races(:senate_maine))
    assert_equal "New Candidate", races(:senate_maine).candidates.order(:id).last.name
  end

  test "create with a blank name redirects with an alert and adds nothing" do
    assert_no_difference "races(:senate_maine).candidates.count" do
      post admin_race_candidates_path(races(:senate_maine)), params: { candidate: { name: "", party: "dem" } }
    end

    assert_redirected_to edit_admin_race_path(races(:senate_maine))
    follow_redirect!
    assert_select "[data-testid='admin-flash-alert']", text: /can't be blank/
  end

  test "update edits name, party, caucus_with, and incumbent" do
    candidate = candidates(:maine_ind)

    patch admin_race_candidate_path(races(:senate_maine), candidate),
          params: { candidate: { name: "Renamed", party: "ind", caucus_with: "rep", incumbent: "1" } }

    assert_redirected_to edit_admin_race_path(races(:senate_maine))
    candidate.reload
    assert_equal "Renamed", candidate.name
    assert_equal "rep", candidate.caucus_with
    assert candidate.incumbent?
  end

  test "update accepts a blank caucus_with without raising" do
    candidate = candidates(:maine_ind)
    patch admin_race_candidate_path(races(:senate_maine), candidate), params: { candidate: { caucus_with: "" } }

    assert_redirected_to edit_admin_race_path(races(:senate_maine))
    assert_nil candidate.reload.caucus_with
  end

  test "destroy removes the candidate and redirects to the race's edit page" do
    candidate = candidates(:maine_ind)

    assert_difference "races(:senate_maine).candidates.count", -1 do
      delete admin_race_candidate_path(races(:senate_maine), candidate)
    end

    assert_redirected_to edit_admin_race_path(races(:senate_maine))
    assert_not Candidate.exists?(candidate.id)
  end

  # M4: destroying a candidate with poll results violates the DB foreign key
  # (poll_results.candidate_id has no ON DELETE clause) and used to 500 as an
  # unhandled ActiveRecord::InvalidForeignKey.
  test "destroy on a candidate with poll results flashes an error instead of raising" do
    candidate = candidates(:maine_dem)
    assert PollResult.exists?(candidate_id: candidate.id), "fixture assumption: maine_dem has poll results"

    assert_no_difference "races(:senate_maine).candidates.count" do
      delete admin_race_candidate_path(races(:senate_maine), candidate)
    end

    assert_redirected_to edit_admin_race_path(races(:senate_maine))
    follow_redirect!
    assert_select "[data-testid='admin-flash-alert']", text: /poll results/
    assert Candidate.exists?(candidate.id)
  end
end
