# One page of /polls: the corpus in the order it arrived, sliced into pages
# and grouped under the day each poll landed.
#
# Ordering is by created_at, not field_end, and the difference is the reason
# this page exists — see Poll.newest_ingested. Nothing links a poll to the
# run that ingested it (Ingest.after_new_polls! passes the ids to the
# forecast job and keeps none), so when the row was written is the only
# record we have of when a poll arrived, and it is an exact one.
#
# A bounded number of queries per page whatever the page size: the total,
# the page's rows, one preload each for pollsters / results / results'
# candidates / races / races' candidates, and the per-day totals for the
# days on the page. Every preload is load-bearing — poll_margin reaches
# through race.candidates via Site::RaceSides, and the row prints each
# result's candidate name — so without them the page costs a query per row.
module Site
  class PollFeed
    PER_PAGE = 100

    # `total` is the whole day's count, which is deliberately not
    # `polls.size`: the source switch landed 1,515 polls in one day, so a day
    # can span many pages, and a heading that renamed itself "100 polls" on
    # each of them would be wrong on every one.
    Day = Struct.new(:date, :total, :polls, keyword_init: true)

    Page = Struct.new(:days, :page, :pages, :total, keyword_init: true) do
      # Clamped to the last real page: a direct caller can still ask for a
      # page past the end, and its "newer" link has to land on rows rather
      # than on the next empty page back.
      def previous_page = page > 1 ? [ page - 1, pages ].min : nil
      def next_page = page < pages ? page + 1 : nil
    end

    def self.build(page:, per_page: PER_PAGE)
      new(page: page, per_page: per_page).build
    end

    # A page number from whatever the query string held. Rack hands over an
    # Array for ?page[]=2 and a Parameters hash for ?page[x]=2, and neither
    # responds to to_i — so it goes through to_s, which turns both into a
    # string to_i reads as zero. Anything under one is page one. There is no
    # upper bound here: PollsController compares the result against last_page
    # and redirects past-the-end requests, which is what keeps every cache
    # keyed on page numbers that exist.
    def self.normalize_page(value)
      [ value.to_s.to_i, 1 ].max
    end

    def self.last_page(total, per_page: PER_PAGE)
      [ (total.to_f / per_page).ceil, 1 ].max
    end

    def initialize(page:, per_page: PER_PAGE)
      @per_page = per_page
      @page = self.class.normalize_page(page)
    end

    def build
      total = scope.count
      Page.new(days: days_for, page: @page, pages: self.class.last_page(total, per_page: @per_page), total: total)
    end

    private
      def scope
        Poll.model_corpus
      end

      def days_for
        polls = scope.newest_ingested
                     .includes(:pollster, race: :candidates, poll_results: :candidate)
                     .offset((@page - 1) * @per_page).limit(@per_page).to_a
        return [] if polls.empty?

        totals = day_totals(polls.last.created_at..polls.first.created_at)
        # fetch without a default on purpose: the SQL grouping and this one
        # read the same rows in the same zone, so a missing key means the two
        # have drifted, and a KeyError is the right response — a fallback to
        # the page-local count would print the very mislabel Day#total
        # exists to prevent, silently.
        polls.group_by { |poll| poll.created_at.in_time_zone.to_date }
             .map { |date, group| Day.new(date: date, total: totals.fetch(date), polls: group) }
      end

      # Per-day counts across the whole corpus for the days this page shows,
      # keyed by the reader's date.
      #
      # The conversion has to happen in SQL — grouping in Ruby would mean
      # loading every timestamp in the table to label a hundred rows — and it
      # has to be the app's zone rather than the database's. created_at is a
      # `timestamp without time zone` holding UTC, so a bare date() would file
      # a poll that arrived at 8pm Eastern under the following day, and print
      # a heading whose count disagreed with the rows beneath it. The sweep
      # runs every two hours, so that is not a rare case: it happens most
      # nights.
      #
      # Bounded to the page's span rather than the whole table: the page's
      # newest and oldest arrivals are already in hand, and every day on the
      # page lies between them. Widened to whole days in the app's zone so a
      # day that straddles the page boundary is still counted in full.
      def day_totals(span)
        from = span.begin.in_time_zone.beginning_of_day
        to = span.end.in_time_zone.end_of_day
        zone = Time.zone.tzinfo.identifier
        expression = Arel.sql(
          "(created_at AT TIME ZONE 'UTC' AT TIME ZONE #{Poll.connection.quote(zone)})::date"
        )
        scope.where(created_at: from..to).group(expression).count.transform_keys { |date| date.to_date }
      end
  end
end
