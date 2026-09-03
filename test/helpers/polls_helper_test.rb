require "test_helper"

class PollsHelperTest < ActionView::TestCase
  # The corpus is four figures and the day the source switch landed is a
  # four-figure day. Every other figure on this site is delimited and set in
  # tabular numerals; a bare 1515 reads as an id, not a count.
  test "poll counts are delimited" do
    assert_equal "1,515 polls", feed_poll_count(1515)
    assert_equal "2 polls", feed_poll_count(2)
    assert_equal "1 poll", feed_poll_count(1)
    assert_equal "0 polls", feed_poll_count(0)
  end
end
