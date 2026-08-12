require "digest"

class Poll < ApplicationRecord
  enum :population, { lv: 0, rv: 1, a: 2, unknown: 3 }, default: :unknown
  enum :entry_mode, { scraped: 0, manual: 1, csv: 2 }

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

  def generic_ballot?
    race_id.nil?
  end

  # "Matt Dunlap (D) vs Paul LePage (R)" — which contest this poll measured,
  # as the source page wrote it. matchup_key is the normalised form the
  # averager compares on; this is the readable one, and falls back to the key
  # for a poll whose provenance cannot supply the labels.
  def matchup_label
    return nil if matchup_key.blank?

    labels = Ingest::Matchup.labels_for_poll(self)
    labels.any? ? labels.join(Ingest::Matchup::SEPARATOR) : Ingest::Matchup.humanize(matchup_key)
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
    def compute_digest(pollster_slug:, race_id:, field_start:, field_end:, results:)
      pairs = results.map do |result|
        result = result.with_indifferent_access
        "#{result["party"]}:#{format("%.1f", result["pct"].to_f)}"
      end.sort

      raw = [ pollster_slug.to_s, race_id.to_s, field_start.to_s, field_end.to_s, pairs.join(",") ].join("|")
      Digest::SHA256.hexdigest(raw)
    end
  end

  private
    def field_end_on_or_after_field_start
      return if field_start.blank? || field_end.blank?

      errors.add(:field_end, "must be on or after field_start") if field_end < field_start
    end
end
