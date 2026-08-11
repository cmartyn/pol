class Candidate < ApplicationRecord
  enum :party, { dem: 0, rep: 1, ind: 2, other: 3 }

  # caucus_with's value set overlaps party's (dem/rep), and both enums live
  # on this table, so it needs a prefix to avoid clashing with party's dem?/
  # rep? methods. Only meaningful when party is ind.
  enum :caucus_with, { dem: 0, rep: 1 }, prefix: :caucus_with

  # touch: true — a candidate add/edit/remove changes what the race page's
  # candidate list and the Senate table show, both cached on the race's
  # updated_at (Phase 4's fragment-cache keys). Covers admin CRUD (Admin::
  # CandidatesController) and Ingest::SeedRaces' post-primary sync/prune
  # (#sync_candidates, #prune_candidates) alike: both go through this
  # association's real AR create/update/destroy, never update_all/
  # delete_all, so the touch callback fires either way.
  belongs_to :race, touch: true

  # The DB has always enforced NOT NULL on name/party (see db/migrate/
  # ..._create_candidates.rb); nothing needed a matching Rails validation
  # while the only writer was Ingest::SeedRaces feeding it trusted YAML.
  # Phase 6's admin is the first place untrusted form input reaches this
  # model, so a blank name now needs to fail gracefully (record.errors) via
  # Admin::CandidatesController rather than raise ActiveRecord::
  # NotNullViolation as an unhandled 500.
  validates :name, presence: true
end
