require "test_helper"

class DispatchTest < ActiveSupport::TestCase
  test "kind enum round-trips every value" do
    Dispatch.kinds.each_key do |value|
      dispatch = Dispatch.new(kind: value)
      assert_equal value, dispatch.kind
    end
  end

  test "status enum round-trips every value" do
    Dispatch.statuses.each_key do |value|
      dispatch = Dispatch.new(status: value)
      assert_equal value, dispatch.status
    end
  end

  test "requires headline" do
    dispatch = Dispatch.new(body_markdown: "body", kind: :daily_brief, status: :published)
    assert_not dispatch.valid?
    assert_includes dispatch.errors[:headline], "can't be blank"
  end

  test "requires body_markdown" do
    dispatch = Dispatch.new(headline: "Headline", kind: :daily_brief, status: :published)
    assert_not dispatch.valid?
    assert_includes dispatch.errors[:body_markdown], "can't be blank"
  end

  test "headline at the configured max length is valid" do
    max = Pol::Params.fetch!(:newsroom, :headline_max_chars)
    dispatch = Dispatch.new(headline: "a" * max, body_markdown: "body", kind: :daily_brief, status: :published)
    assert dispatch.valid?
  end

  test "headline one character over the configured max length is invalid" do
    max = Pol::Params.fetch!(:newsroom, :headline_max_chars)
    dispatch = Dispatch.new(headline: "a" * (max + 1), body_markdown: "body", kind: :daily_brief, status: :published)
    assert_not dispatch.valid?
    assert_includes dispatch.errors[:headline], "is too long (maximum is #{max} characters)"
  end

  test "headline max length is read from Pol::Params at validation time, not hardcoded" do
    dispatch = Dispatch.new(headline: "a" * 6, body_markdown: "body", kind: :daily_brief, status: :published)

    with_stubbed_headline_max_chars(5) do
      assert_not dispatch.valid?
      assert_includes dispatch.errors[:headline], "is too long (maximum is 5 characters)"
    end

    assert dispatch.valid?, "should be valid again once the stub is gone and the real 90-char cap applies"
  end

  test "recent_first orders by published_at descending" do
    older = Dispatch.create!(
      headline: "Older dispatch", body_markdown: "body", kind: :daily_brief, status: :published,
      published_at: "2026-07-01 09:00:00"
    )

    ordered = Dispatch.where(id: [ older.id, dispatches(:maine_poll_reaction).id ]).recent_first
    assert_equal [ dispatches(:maine_poll_reaction), older ], ordered.to_a
  end

  test "published.recent_first excludes retracted dispatches and orders the rest by published_at" do
    older_published = Dispatch.create!(
      headline: "Older dispatch", body_markdown: "body", kind: :daily_brief, status: :published,
      published_at: "2026-07-01 09:00:00"
    )
    newer_retracted = Dispatch.create!(
      headline: "Retracted dispatch", body_markdown: "body", kind: :daily_brief, status: :retracted,
      published_at: "2026-08-05 09:00:00"
    )

    ordered = Dispatch.where(id: [ older_published.id, newer_retracted.id, dispatches(:maine_poll_reaction).id ])
      .published.recent_first

    assert_equal [ dispatches(:maine_poll_reaction), older_published ], ordered.to_a
  end

  test "cited_poll_ids defaults to an empty array" do
    assert_equal [], Dispatch.new.cited_poll_ids
  end

  test "cited_poll_ids fixture references the polls it cites" do
    dispatch = dispatches(:maine_poll_reaction)
    assert_includes dispatch.cited_poll_ids, polls(:maine_poll_one).id
    assert_includes dispatch.cited_poll_ids, polls(:maine_poll_two).id
  end

  test "citing_any finds the dispatches that already cite a poll" do
    other = Dispatch.create!(headline: "Elsewhere", body_markdown: "body", kind: :poll_reaction,
                             status: :published, published_at: Time.current, cited_poll_ids: [ 4242 ])

    assert_equal [ dispatches(:maine_poll_reaction) ], Dispatch.citing_any([ polls(:maine_poll_one).id ]).to_a
    assert_equal [ other ], Dispatch.citing_any([ 4242 ]).to_a
    assert_equal 2, Dispatch.citing_any([ polls(:maine_poll_two).id, 4242 ]).count
  end

  test "citing_any matches whole ids, not digits inside them" do
    Dispatch.create!(headline: "Elsewhere", body_markdown: "body", kind: :poll_reaction,
                     status: :published, published_at: Time.current, cited_poll_ids: [ 12_345 ])

    assert_empty Dispatch.citing_any([ 123 ])
    assert_empty Dispatch.citing_any([ 2345 ])
    assert_equal 1, Dispatch.citing_any([ 12_345 ]).count
  end

  test "citing_any of nothing matches nothing, rather than everything" do
    assert_empty Dispatch.citing_any([])
    assert_empty Dispatch.citing_any(nil)
  end

  # The scope ORs one containment test per id together, so it has to narrow
  # whatever relation it is chained onto rather than OR-ing itself around it.
  # Newsroom::Caps#duplicate chains it exactly this way; if the OR ever escaped
  # its own parentheses the duplicate guard would start matching dispatches for
  # other races and the newsroom would go quiet for no reason.
  test "citing_any narrows the relation it is chained onto" do
    elsewhere = Dispatch.create!(headline: "Elsewhere", body_markdown: "body", kind: :poll_reaction,
                                 status: :published, published_at: Time.current,
                                 race: races(:senate_florida_special), cited_poll_ids: [ 4242 ])
    ids = [ polls(:maine_poll_one).id, 4242 ]

    assert_equal 2, Dispatch.citing_any(ids).count
    assert_equal [ elsewhere ], Dispatch.where(race: races(:senate_florida_special)).citing_any(ids).to_a
    assert_equal [ dispatches(:maine_poll_reaction) ], Dispatch.citing_any(ids).where(race: races(:senate_maine)).to_a
    assert_empty Dispatch.retracted.citing_any(ids)
  end

  test "a dispatch that cites nothing is not caught by the duplicate guard" do
    dispatches(:maine_poll_reaction).update!(cited_poll_ids: [])

    assert_empty Dispatch.citing_any([ polls(:maine_poll_one).id ])
  end

  private
    # Minitest 6 no longer bundles Object#stub (it moved to a separate
    # minitest-mock gem we don't depend on), so this replaces
    # Pol::Params.fetch! by hand for the duration of the block — only for
    # the :newsroom/:headline_max_chars lookup, delegating everything else
    # to the real implementation — and restores it afterward.
    def with_stubbed_headline_max_chars(value)
      original = Pol::Params.method(:fetch!)
      Pol::Params.define_singleton_method(:fetch!) do |*keys, **kwargs|
        keys == [ :newsroom, :headline_max_chars ] ? value : original.call(*keys, **kwargs)
      end
      yield
    ensure
      Pol::Params.define_singleton_method(:fetch!, original)
    end
end
