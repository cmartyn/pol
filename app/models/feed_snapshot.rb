require "zlib"

# A gzipped copy of one fetched feed file, kept only when its content
# changed. The NYT CSVs come with no license and no API contract; if the
# Times moves or reshapes them, these rows are what the corpus can be
# rebuilt or audited from.
class FeedSnapshot < ApplicationRecord
  validates :source, :digest, :body, :fetched_at, presence: true

  scope :for_source, ->(source) { where(source: source) }

  # Store `body` for `source` unless this exact content is already held.
  # Returns the snapshot when one was written, nil when the content was
  # already known — which doubles as the caller's "did the feed change?".
  def self.record!(source:, body:, fetched_at: Time.current)
    digest = Digest::SHA256.hexdigest(body)
    return nil if exists?(source: source, digest: digest)

    create!(source: source, digest: digest, fetched_at: fetched_at,
            body: Zlib.gzip(body))
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # How many versions to keep per source. The newest snapshot alone can
  # rebuild the corpus; the rest are diagnostics, and the file changes a few
  # times a day, so a hundred covers about a month of history without
  # letting megabyte bodies accumulate all cycle.
  KEEP_PER_SOURCE = 100

  def self.latest_for(source)
    for_source(source).order(fetched_at: :desc, id: :desc).first
  end

  # The newest snapshot's metadata without its body — the sync reads
  # fetched_at and digest every sweep, and dragging the gzipped file across
  # the wire to read a timestamp is the one cost this table must not have.
  def self.latest_meta_for(source)
    for_source(source).order(fetched_at: :desc, id: :desc)
                      .select(:id, :source, :digest, :fetched_at).first
  end

  def self.prune!(source)
    stale_ids = for_source(source).order(fetched_at: :desc, id: :desc)
                                  .offset(KEEP_PER_SOURCE).pluck(:id)
    where(id: stale_ids).delete_all if stale_ids.any?
  end

  def csv_body
    Zlib.gunzip(body)
  end
end
