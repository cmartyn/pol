module Ingest
  module Nyt
    module CandidateIdentity
      # The feed gives James Davis and Jamie Davis separate IDs. His own
      # campaign identifies him as James "Jamie" Davis Jr.:
      # https://jamieforlouisiana.com/
      # This is an explicit, sourced alias, never a surname-based merge.
      ALIASES = {
        "9eef7bf6-19a9-4d47-a81e-3e352f1a5c4a" => "fa6b2ecd-5ecc-4d0c-b1fc-65c92e59bd7c",
        # Gabe/Gabriel Vasquez: https://www.fec.gov/data/candidate/H2NM02191/
        "b3f0fa2c-9ccc-44a2-9ebf-610013e1d27c" => "b3d290b3-95a5-44a7-bdd9-7918c2b37668",
        # Thomas Roland/Thom Tillis, legal name and ballot name:
        # https://www.onslowcountync.gov/DocumentCenter/View/10054/March-2020-Final-Onslow-County-Candidate-List
        "6a1d206e-9594-4a3b-a8fb-dd5b40edf554" => "a349d652-51d4-4a4d-a5a4-0a97619d9352"
      }.freeze

      def self.canonical(id)
        ALIASES.fetch(id, id)
      end
    end
  end
end
