module PollsHelper
  # "1,515 polls". Deliberately not #pluralize, which renders the count
  # undelimited: the corpus is four figures, the day the source switch landed
  # is a four-figure day, and every other number this site prints is delimited
  # and set in tabular numerals. A bare 1515 reads as an id.
  def feed_poll_count(count)
    "#{number_with_delimiter(count)} #{'poll'.pluralize(count)}"
  end

  # "Arrived August 20, 2026". Spelled out rather than abbreviated because
  # this is the axis the page is organised on, and it should not read like
  # another data cell.
  def feed_day_heading(date)
    "Arrived #{date.strftime('%B %-d, %Y')}"
  end

  # Page one is /polls, not /polls?page=1 — one URL per page for the edge
  # cache and for anyone linking to it.
  def feed_page_path(page)
    page > 1 ? polls_path(page: page) : polls_path
  end
end
