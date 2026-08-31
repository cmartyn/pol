require "digest"

class Poll < ApplicationRecord
  enum :population, { lv: 0, rv: 1, a: 2, unknown: 3 }, default: :unknown
  enum :entry_mode, { scraped: 0, manual: 1, csv: 2, nyt: 3 }

  # Sponsor-party flag carried by the NYT feed. Prefixed because a bare
  # `none` scope would collide with ActiveRecord::Relation#none.
  enum :partisan, { none: 0, dem: 1, rep: 2, ind: 3, oth: 4 }, prefix: true

  belongs_to :pollster
  belongs_to :race, optional: true
  has_many :poll_results, dependent: :destroy

  validates :field_end, presence: true
  validates :source_url, presence: true

  # Ingestion, manual entry, and CSV import (all later phases) compute the
  # digest themselves via .compute_digest and assign it BEFORE calling save.
  # We deliberately do NOT compute it in a before_validation/before_save
  # callback here: the digest is derived from this poll's results, and the
  # poll_results children aren't reliably built/persisted yet at the
  # parent's callback time. Presence is still validated so a poll can never
  # be saved without one.
  validates :dedup_digest, presence: true

  validate :field_end_on_or_after_field_start

  scope :for_generic_ballot, -> { where(race_id: nil) }
  scope :recent_first, -> { order(field_end: :desc, id: :desc) }

  # The polls the model reads: every entry door except the retired
  # Wikipedia-scraped rows, which stay in the table for provenance but must
  # never mix back in — the two sources name pollsters differently, and
  # letting both in would double-count every poll they share. Retirement is
  # the marked case, so a new door (the admin CSV import, a future feed) is
  # in the corpus unless it opts out.
  scope :model_corpus, -> { where.not(entry_mode: :scraped) }

  # Flagged as sponsored by a party-aligned client. What the internals
  # toggle includes or excludes.
  scope :internal, -> { where.not(partisan: :none) }

  def generic_ballot?
    race_id.nil?
  end

  # Sponsored by a party-aligned client — the polls the internals toggle is
  # about. Broader than a campaign internal: the flag comes from the feed's
  # `partisan` column (any party-aligned sponsor), NOT its `internal` column
  # — wiring that narrower column in here would silently shrink the
  # toggle's population.
  def internal?
    !partisan_none?
  end

  # "Matt Dunlap (D) vs Paul LePage (R)" — which contest this poll measured,
  # as the source page wrote it. matchup_key is the normalised form the
  # averager compares on; this is the readable one, and falls back to the key
  # for a poll whose provenance cannot supply the labels.
  def matchup_label
    return nil if matchup_key.blank?

    labels = Ingest::Matchup.labels_for_poll(self)
    labels.any? ? labels.join(" vs ") : Ingest::Matchup.humanize(matchup_key)
  end

  # One side of this poll was a placeholder — "Generic Republican" — rather
  # than a person. The parser refuses those tables now; a few rows predate the
  # guard, and Forecast::Averager leaves them out of the average.
  def placeholder_opponent?
    Ingest::Matchup.placeholder_opponent?(self)
  end

  # What to head this poll's group with on a page that lists polls by matchup.
  # A poll with no matchup is not a mystery — it is a poll that named nobody to
  # run against, and the heading says which kind rather than shrugging.
  def matchup_heading
    matchup_label ||
      (placeholder_opponent? ? "Against a generic opponent — not in the average" : "Matchup not recorded")
  end

  class << self
    # Poll.compute_digest(pollster_slug: "beacon-polling", race_id: 1,
    #   field_start: Date.new(2026, 7, 1), field_end: Date.new(2026, 7, 5),
    #   results: [ { party: "dem", pct: 47.5 }, { party: "rep", pct: 44.0 } ])
    #
    # SHA256 hex digest of a stable string built from the given values.
    # `results` is an array of hashes (indifferent-access) with "party" and
    # "pct" entries; each is rendered as a "party:pct" pair with pct rounded
    # to 1 decimal, then the pairs are sorted before joining. Rounding makes
    # sub-tenth float noise a non-issue, and sorting makes the digest
    # independent of the order results were passed in — two polls with the
    # same pollster/race/dates/results hash identically either way, which is
    # exactly what dedup needs.
    # `salt` distinguishes rows the base fields cannot: two NYT questions in
    # one poll (an LV and an RV read, say) can share pollster, race, dates
    # and even toplines, and without the question id in the digest the second
    # would be swallowed as a duplicate of the first. Legacy callers pass
    # nothing and their digests are unchanged.
    def compute_digest(pollster_slug:, race_id:, field_start:, field_end:, results:, salt: nil)
      pairs = results.map do |result|
        result = result.with_indifferent_access
        "#{result["party"]}:#{format("%.1f", result["pct"].to_f)}"
      end.sort

      raw = [ pollster_slug.to_s, race_id.to_s, field_start.to_s, field_end.to_s, pairs.join(",") ].join("|")
      raw << "|#{salt}" if salt.present?
      Digest::SHA256.hexdigest(raw)
    end
  end

  private
    def field_end_on_or_after_field_start
      return if field_start.blank? || field_end.blank?

      errors.add(:field_end, "must be on or after field_start") if field_end < field_start
    end
end
