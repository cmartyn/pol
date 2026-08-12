module Ingest
  # Who a poll actually tested, recorded per party slot so two polls can be
  # compared on the sides an average will read.
  #
  #   Ingest::Matchup.key(["Mike Lawler (R)", "Cait Conley (D)", "Undecided"])
  #   # => "dem:conley|rep:lawler"
  #
  # A page publishes several general-election tables for one race while the
  # nominees are unsettled — Maine's 2nd carries four different Democrats
  # against Paul LePage — and nothing in a row says which of them will be the
  # contest on the ballot. Averaging across them produces a margin for a
  # matchup nobody is running in. This key is what lets the averager notice,
  # and what lets a race page group its polls by the question they asked.
  #
  # Keyed by party rather than flattened into a list, because that is the only
  # form that answers the question the averager has to ask. Montana polls
  # Bankhead against Alme both two-way and three-way with Seth Bodnar; those
  # are the same contest between the same two people with a third option
  # offered, and a flat list of names calls them different matchups. Reading
  # per side — "who was the Democrat, who was the Republican" — gets Montana
  # right and still catches Maine, where the Democrat is a different person
  # each time.
  #
  # Values are normalised (surname only, suffixes and accents dropped,
  # downcased) so two spellings of one name agree, and the parties are sorted
  # so column order cannot matter.
  module Matchup
    SEPARATOR = "|".freeze
    PAIR = ":".freeze
    # Order to read a key back in when rendering it for a person.
    DISPLAY_ORDER = %w[dem rep ind other].freeze

    class << self
      # nil unless at least two parties named a person: a column reading
      # "Democratic" (the generic ballot) names nobody, and one name alone is
      # not a matchup.
      def key(labels)
        named = named_by_party(labels)
        return nil if named.size < 2

        named.sort.map { |party, surname| "#{party}#{PAIR}#{surname}" }.join(SEPARATOR)
      end

      # { "dem" => "conley", "rep" => "lawler" }
      def parse(key)
        key.to_s.split(SEPARATOR).to_h do |pair|
          party, surname = pair.split(PAIR, 2)
          [ party, surname ]
        end
      end

      # The labels themselves, for a page showing a reader which contest a poll
      # measured. Sorted, so two polls of one matchup read the same way round.
      def labels(labels)
        Array(labels).select { |label| party_of(label) }.uniq.sort
      end

      def party_of(label)
        text = label.to_s
        PollTableParser::TAGGED_PARTY.each_key.find { |party| text.match?(PollTableParser::TAGGED_PARTY.fetch(party)) }
      end

      # "Conley vs Lawler" — the key made presentable, for a poll whose stored
      # cell map cannot supply the labels as they were written.
      def humanize(key)
        by_party = parse(key)
        ordered = DISPLAY_ORDER.filter_map { |party| by_party[party] } + by_party.except(*DISPLAY_ORDER).values
        ordered.map(&:capitalize).join(" vs ")
      end

      # The key for a poll already in the table, rebuilt from the cell map its
      # provenance kept.
      def for_poll(poll)
        key(columns_of(poll))
      end

      # A poll one of whose sides was a placeholder rather than a person —
      # "Generic Republican", "Another Democratic candidate". The parser
      # refuses these now (`generic_candidate_column`), but four were read
      # before it did and are still in the corpus. They carry no matchup key,
      # because a placeholder is not a name, so the ambiguity rule cannot see
      # them; the averager drops them on this instead.
      def placeholder_opponent?(poll)
        columns = poll.raw_payload.is_a?(Hash) ? poll.raw_payload["columns"] : nil
        return false if columns.blank?

        columns.keys.any? do |label|
          label.match?(PollTableParser::GENERIC_CANDIDATE) &&
            (party_of(label) || PollTableParser::BARE_PARTY.each_value.any? { |p| label.match?(p) })
        end
      end

      # ["Matt Dunlap (D)", "Paul LePage (R)"] — the contest as the page wrote
      # it, which is what a reader should see rather than a normalised key.
      def labels_for_poll(poll)
        labels(columns_of(poll))
      end

      private
        # One surname per party. Where a party has two columns — a top-two
        # general between two Democrats, a table carrying both a Libertarian
        # and a Green — the first is taken; no race the model runs reads a
        # side that ambiguous, and the alternative is a key that cannot be
        # compared per side at all.
        def named_by_party(labels)
          Array(labels).each_with_object({}) do |label, named|
            party = party_of(label)
            next if party.nil?

            surname = PollTableParser.surname(label).presence
            named[party.to_s] ||= surname if surname
          end
        end

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
    end
  end
end
