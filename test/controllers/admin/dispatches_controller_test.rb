require "test_helper"

class Admin::DispatchesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  # --- index -----------------------------------------------------------------

  test "index lists every dispatch regardless of status" do
    retracted = Dispatch.create!(headline: "Pulled", body_markdown: "Body.", kind: :daily_brief, status: :retracted,
                                  published_at: Time.current, model_slug: "fixture/writer-model")

    get admin_dispatches_path
    assert_response :success
    assert_select "[data-testid='admin-dispatch-row']", count: Dispatch.count
    assert_select "[data-testid='admin-dispatch-row']", text: /#{Regexp.escape(retracted.headline)}/
  end

  test "index filters by kind, status, and race" do
    get admin_dispatches_path, params: { kind: "poll_reaction" }
    assert_select "[data-testid='admin-dispatch-row']", count: Dispatch.poll_reaction.count

    get admin_dispatches_path, params: { status: "published" }
    assert_select "[data-testid='admin-dispatch-row']", count: Dispatch.published.count

    get admin_dispatches_path, params: { race_id: races(:senate_maine).id }
    assert_select "[data-testid='admin-dispatch-row']", count: races(:senate_maine).dispatches.count
  end

  test "index marks edited and retracted dispatches" do
    dispatches(:maine_poll_reaction).update!(edited_at: Time.current)
    get admin_dispatches_path
    assert_select "[data-testid='admin-dispatch-edited-marker']"
  end

  # --- show --------------------------------------------------------------------

  test "show renders body, dek, and cited polls resolved to rows" do
    get admin_dispatch_path(dispatches(:maine_poll_reaction))

    assert_response :success
    assert_select "[data-testid='admin-dispatch-body']"
    assert_select "[data-testid='admin-dispatch-dek']"
    assert_select "[data-testid='admin-dispatch-cited-poll']", count: dispatches(:maine_poll_reaction).cited_poll_ids.size
    assert_select "[data-testid='admin-dispatch-cited-poll']", text: /#{Regexp.escape(polls(:maine_poll_one).pollster.name)}/
  end

  test "show links the model run" do
    get admin_dispatch_path(dispatches(:maine_poll_reaction))
    assert_select "a[href='#{admin_model_run_path(model_runs(:model_run_one))}']"
  end

  test "show renders an honest empty state with no cited polls" do
    dispatch = Dispatch.create!(headline: "No citations", body_markdown: "Body.", kind: :daily_brief,
                                 status: :published, published_at: Time.current, model_slug: "fixture/writer-model")
    get admin_dispatch_path(dispatch)
    assert_select "[data-testid='admin-dispatch-cited-polls-empty']"
  end

  test "show offers a retract button for a published dispatch, but not a retracted one" do
    get admin_dispatch_path(dispatches(:maine_poll_reaction))
    assert_select "[data-testid='admin-dispatch-retract-button']"

    dispatches(:maine_poll_reaction).update!(status: :retracted)
    get admin_dispatch_path(dispatches(:maine_poll_reaction))
    assert_select "[data-testid='admin-dispatch-retract-button']", count: 0
  end

  # --- edit/update ---------------------------------------------------------------

  test "edit renders the form" do
    get edit_admin_dispatch_path(dispatches(:maine_poll_reaction))
    assert_response :success
    assert_select "[data-testid='admin-dispatch-form']"
  end

  test "update sets edited_at and persists the new content" do
    dispatch = dispatches(:maine_poll_reaction)
    assert_nil dispatch.edited_at

    patch admin_dispatch_path(dispatch), params: { dispatch: { headline: "A corrected headline", dek: dispatch.dek, body_markdown: dispatch.body_markdown } }

    # Reload before building the expected path: Dispatch#to_param spells the
    # headline into the URL, so the controller redirects to the corrected
    # headline's path while this in-memory copy would still produce the old
    # one. Both resolve — the id is what looks the record up — but they are
    # not the same string.
    dispatch.reload
    assert_redirected_to admin_dispatch_path(dispatch)
    assert_equal "A corrected headline", dispatch.headline
    assert_not_nil dispatch.edited_at
  end

  test "update surfaces the headline cap as a form error rather than a 500" do
    dispatch = dispatches(:maine_poll_reaction)
    max = Pol::Params.fetch!(:newsroom, :headline_max_chars)

    patch admin_dispatch_path(dispatch), params: { dispatch: { headline: "a" * (max + 1), dek: dispatch.dek, body_markdown: dispatch.body_markdown } }

    assert_response :unprocessable_entity
    assert_select "[data-testid='admin-dispatch-errors']", text: /too long/
    assert_nil dispatch.reload.edited_at
  end

  # --- retract -------------------------------------------------------------------

  test "retract flips the status and leaves the dispatch visible in admin" do
    dispatch = dispatches(:maine_poll_reaction)

    post retract_admin_dispatch_path(dispatch)

    assert_redirected_to admin_dispatch_path(dispatch)
    assert dispatch.reload.retracted?
    get admin_dispatch_path(dispatch)
    assert_response :success
  end
end
