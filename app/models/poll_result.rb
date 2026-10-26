class PollResult < ApplicationRecord
  enum :party, { dem: 0, rep: 1, ind: 2, other: 3 }

  belongs_to :poll
  belongs_to :candidate, optional: true

  validates :party, presence: true
  validates :pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  def display_name
    candidate_name.presence || candidate&.name || party.humanize
  end

  def source_identity
    Ingest::Nyt::CandidateIdentity.canonical(source_candidate_id.presence)
  end

  def self.normalized_name(name)
    I18n.transliterate(name.to_s).downcase.gsub(/[^a-z0-9]+/, " ").strip
  end
end
