require "test_helper"

class Admin::PollImportsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  HEADER = "race_slug,pollster,field_start,field_end,sample_size,population,sponsor,source_url," \
           "dem_pct,rep_pct,ind_pct,other_pct,dem_candidate,rep_candidate,ind_candidate".freeze

  def upload_for(*rows)
    content = ([ HEADER ] + rows).join("\n") + "\n"
    Rack::Test::UploadedFile.new(StringIO.new(content), "text/csv", original_filename: "polls.csv")
  end

  test "new renders the upload form and the documented column format" do
    get new_admin_poll_import_path
    assert_response :success
    assert_select "[data-testid='admin-poll-import-form']"
    assert_select "[data-testid='admin-poll-import-docs']"
  end

  test "create with no file redirects with an alert" do
    post admin_poll_imports_path
    assert_redirected_to new_admin_poll_import_path
    follow_redirect!
    assert_select "[data-testid='admin-flash-alert']", text: /Choose a CSV file/
  end

  test "create imports a valid row and shows it as created with a link to the poll" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,lv,,https://example.com/import-1,48.0,44.5,,,,,"

    assert_difference "Poll.count", 1 do
      post admin_poll_imports_path, params: { file: upload_for(row) }
    end

    assert_response :success
    assert_select "[data-testid='admin-poll-import-created-count']", text: "1 created"
    poll = Poll.order(:created_at).last
    assert_select "[data-testid='admin-poll-import-row'] a[href='#{admin_poll_path(poll)}']"
  end

  test "create reports a mixed file's outcomes with line numbers" do
    good = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-01,700,lv,,https://example.com/import-2,48.0,44.0,,,,,"
    bad = ",Broken,,2026-08-02,700,lv,,,48.0,44.0,,,,," # no source_url

    post admin_poll_imports_path, params: { file: upload_for(good, bad, good) }

    assert_response :success
    assert_select "[data-testid='admin-poll-import-created-count']", text: "1 created"
    assert_select "[data-testid='admin-poll-import-duplicate-count']", text: "1 duplicate"
    assert_select "[data-testid='admin-poll-import-invalid-count']", text: "1 invalid"
    rows = css_select("[data-testid='admin-poll-import-row']")
    assert_equal "2", rows[0].css("td").first.text.strip
    assert_equal "3", rows[1].css("td").first.text.strip
    assert_equal "4", rows[2].css("td").first.text.strip
  end

  test "create touches the race for a newly imported poll" do
    races(:senate_maine).update_column(:updated_at, 1.day.ago)
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,lv,,https://example.com/import-3,48.0,44.5,,,,,"

    post admin_poll_imports_path, params: { file: upload_for(row) }

    assert races(:senate_maine).reload.updated_at > 23.hours.ago
  end
end
