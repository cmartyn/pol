# The dashboard's one-time note that the poll corpus changed sources — up
# while the switch is fresh enough to explain the movers, gone on its own
# after site.corpus_note_days.
#
# Armed by the data rather than by configuration: the clock starts at the
# first NYT-feed poll's created_at in this environment's database, which is
# the moment the backfill actually landed — not the moment anyone remembered
# to flip a flag. An environment with no feed polls shows nothing.
class Site::CorpusNote
  def initialize(days: Pol::Params.fetch!(:site, :corpus_note_days))
    @days = days
  end

  # The day the feed corpus arrived, as this database remembers it.
  # Cached: this sits on the homepage's cache-miss path and the answer is
  # monotone — once armed it can only move earlier — so an hour of staleness
  # costs nothing while sparing an unindexed scan per render.
  def since
    return @since if defined?(@since)

    @since = Rails.cache.fetch("corpus_note/since", expires_in: 1.hour) do
      Poll.nyt.minimum(:created_at)&.to_date
    end
  end

  def expires_on
    since && since + @days
  end

  def visible?(on: Date.current)
    return false if since.nil?

    on < expires_on
  end
end
