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
