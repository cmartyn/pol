module Ingest
  # Who a poll actually tested, reduced to a key two polls can be compared on.
  #
  #   Ingest::Matchup.key(["Mike Lawler (R)", "Cait Conley (D)", "Undecided"])
  #   # => "conley vs lawler"
  #
  # A House page publishes several general-election tables per district while
  # the nominees are unsettled — Maine's 2nd carries four different Democrats
  # against Paul LePage — and nothing in a row says which of them will be the
  # contest on the ballot. Averaging across them produces a margin for a
  # matchup nobody is running in. This key is what lets the averager notice,
  # and what lets a race page group its polls by the question they asked.
  #
  # Normalised (surname only, suffixes and accents dropped, downcased) so two
  # spellings of one contest agree, and sorted so column order cannot matter.
  module Matchup
    # Parties whose column names one of the people the contest is between. A
    # Libertarian or Conservative line comes and goes between tables without
    # changing who the race is between, so it is left out: "Lawler vs Conley"
    # and "Lawler vs Conley vs a Conservative" are the same matchup.
    NAMED_PARTIES = %i[dem rep ind].freeze
    SEPARATOR = " vs ".freeze

    class << self
      # nil unless at least two columns named a person: a column reading
      # "Democratic" (the generic ballot) names nobody, and one name alone is
      # not a matchup.
      def key(labels)
        names = Array(labels).filter_map { |label| surname_of(label) }.uniq.sort
        return nil if names.size < 2

        names.join(SEPARATOR)
      end

      # The labels themselves, for a page showing a reader which contest a poll
      # measured. Sorted, so two polls of one matchup read the same way round.
      def labels(labels)
        Array(labels).select { |label| party_of(label) }.uniq.sort
      end

      def party_of(label)
        text = label.to_s
        NAMED_PARTIES.find { |party| text.match?(PollTableParser::TAGGED_PARTY.fetch(party)) }
      end

      # "Dunlap vs Lepage" — the key made presentable, for a poll whose stored
      # cell map cannot supply the labels as they were written.
      def humanize(key)
        key.to_s.split(SEPARATOR).map(&:capitalize).join(SEPARATOR)
      end

      # The key for a poll already in the table, rebuilt from the cell map its
      # provenance kept.
      def for_poll(poll)
        key(columns_of(poll))
      end

      # ["Matt Dunlap (D)", "Paul LePage (R)"] — the contest as the page wrote
      # it, which is what a reader should see rather than a normalised key.
      def labels_for_poll(poll)
        labels(columns_of(poll))
      end

      private
        # Columns for a party the poll returned no result for are dropped,
        # which is what makes a rebuilt key agree with the one the parser
        # computes live: a dashed independent column is a candidate who was
        # not tested in that row.
        def columns_of(poll)
          columns = poll.raw_payload.is_a?(Hash) ? poll.raw_payload["columns"] : nil
          return [] if columns.blank?

          parties = poll.poll_results.map { |result| result.party.to_sym }
          columns.keys.select { |label| parties.include?(party_of(label)) }
        end

        def surname_of(label)
          return nil unless party_of(label)

          PollTableParser.surname(label).presence
        end
    end
  end
end
