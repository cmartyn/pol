class Candidate < ApplicationRecord
  enum :party, { dem: 0, rep: 1, ind: 2, other: 3 }

  # caucus_with's value set overlaps party's (dem/rep), and both enums live
  # on this table, so it needs a prefix to avoid clashing with party's dem?/
  # rep? methods. Only meaningful when party is ind.
  enum :caucus_with, { dem: 0, rep: 1 }, prefix: :caucus_with

  belongs_to :race
end
