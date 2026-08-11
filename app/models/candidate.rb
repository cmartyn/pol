class Candidate < ApplicationRecord
  enum :party, { dem: 0, rep: 1, ind: 2, other: 3 }

  # caucus_with's value set overlaps party's (dem/rep), and both enums live
  # on this table, so it needs a prefix to avoid clashing with party's dem?/
  # rep? methods. Only meaningful when party is ind.
  enum :caucus_with, { dem: 0, rep: 1 }, prefix: :caucus_with

  belongs_to :race

  # The DB has always enforced NOT NULL on name/party (see db/migrate/
  # ..._create_candidates.rb); nothing needed a matching Rails validation
  # while the only writer was Ingest::SeedRaces feeding it trusted YAML.
  # Phase 6's admin is the first place untrusted form input reaches this
  # model, so a blank name now needs to fail gracefully (record.errors) via
  # Admin::CandidatesController rather than raise ActiveRecord::
  # NotNullViolation as an unhandled 500.
  validates :name, presence: true
end
