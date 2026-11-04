require "json"

module ElectionNight
  # Enhanced Voting exports repeat precinct and voting-method details under
  # every candidate. The county-level adapter reads only candidate voteCount.
  # JSON's bottom-up on_load callback releases these unused descendants as
  # each object is parsed, rather than retaining the entire expanded tree.
  #
  # This still validates the complete JSON document. It does not skip input
  # bytes, infer totals from subtotals, or weaken the adapter's validation.
  # Keep this opt-in: a future precinct/method adapter must use normal parsing.
  module SummaryJson
    PRUNE_DETAILS = lambda do |value|
      if value.is_a?(Hash)
        value.delete("precinctResults")
        value.delete("groupResults")
      end
      value
    end
    private_constant :PRUNE_DETAILS

    def self.parse(body)
      JSON.parse(body, on_load: PRUNE_DETAILS)
    end
  end
end
