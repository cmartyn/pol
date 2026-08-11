module Newsroom
  # Our side of the output contract. The schema we send OpenRouter asks for
  # these four fields; this is what decides whether what came back may be
  # published, and it assumes nothing about the model having complied.
  #
  # There is no approval queue behind this, so it is deliberately unforgiving:
  # anything it cannot vouch for is rejected, the model gets exactly one more
  # turn with these messages, and a second failure publishes nothing at all.
  class Validation
    MAX_STRUCTURE_SAMPLE = 60

    # Markdown the site does not render. app/views/dispatches/_dispatch.html.erb
    # runs body_markdown through simple_format, which turns blank lines into
    # paragraphs and passes everything else through as text — so a heading
    # would publish as a literal "## " and a bullet list as a run-on line.
    STRUCTURE_PATTERNS = {
      "a markdown heading" => /^\s{0,3}\#{1,6}\s/,
      "a bullet list" => /^\s{0,3}[-*+]\s+\S/,
      "a numbered list" => /^\s{0,3}\d+[.)]\s+\S/,
      "a block quote" => /^\s{0,3}>\s?/,
      "a code fence" => /^\s{0,3}```/,
      "a table row" => /^\s{0,3}\|.*\|/
    }.freeze

    def self.call(...)
      new(...).call
    end

    # data: the parsed JSON object from the model (or nil if it wasn't JSON).
    # citable_poll_ids: the payload's poll ids — the only ids that may be cited.
    def initialize(data, kind:, citable_poll_ids:)
      @data = data
      @kind = kind.to_sym
      @citable_poll_ids = Array(citable_poll_ids).map(&:to_i)
    end

    # => [] when the draft may be published, otherwise the reasons it may not.
    # The messages are written to be read twice: by a human in newsroom_skips,
    # and by the model on the retry turn.
    def call
      return [ "the reply was not a JSON object matching the schema" ] unless @data.is_a?(Hash)

      errors = []
      errors.concat(headline_errors)
      errors.concat(dek_errors)
      errors.concat(body_errors)
      errors.concat(citation_errors)
      errors
    end

    private
      def headline_errors
        limit = Pol::Params.fetch!(:newsroom, :headline_max_chars)
        length_errors(:headline, limit, "characters")
      end

      def dek_errors
        limit = Pol::Params.fetch!(:newsroom, :dek_max_chars)
        length_errors(:dek, limit, "characters")
      end

      def length_errors(field, limit, unit)
        value = string(field)
        return [ "#{field} is missing" ] if value.blank?

        length = value.length
        return [] if length <= limit

        [ "#{field} is #{length} #{unit}; the limit is #{limit}" ]
      end

      def body_errors
        body = string(:body_markdown)
        return [ "body_markdown is missing" ] if body.blank?

        errors = []
        limit = Pol::Params.fetch!(:newsroom, :body_max_words)
        words = body.split(/\s+/).count { |word| word.match?(/\S/) }
        errors << "body_markdown is #{words} words; the limit is #{limit}" if words > limit

        STRUCTURE_PATTERNS.each do |name, pattern|
          match = body[pattern]
          next unless match

          errors << "body_markdown contains #{name} (#{match.strip.truncate(MAX_STRUCTURE_SAMPLE).inspect}); " \
                    "the site renders plain paragraphs only"
        end

        errors
      end

      # Strict by design: a citation we cannot resolve to a poll in the payload
      # is the one failure mode that would put a fabricated source on the page.
      def citation_errors
        cited = @data["cited_poll_ids"]
        return [ "cited_poll_ids must be an array of poll ids from citable_poll_ids" ] unless cited.is_a?(Array)

        integers, rest = cited.partition { |id| id.is_a?(Integer) || id.to_s.match?(/\A-?\d+\z/) }
        errors = []
        errors << "cited_poll_ids contains #{rest.inspect}, which are not poll ids" if rest.any?

        uncitable = integers.map(&:to_i) - @citable_poll_ids
        if uncitable.any?
          errors << "cited_poll_ids contains #{uncitable.inspect}, which #{uncitable.one? ? 'is' : 'are'} not in " \
                    "citable_poll_ids (#{@citable_poll_ids.inspect})"
        end

        # A reaction to new polls that cites none of them is not a reaction to
        # them: nothing in it can be traced to a source. Other kinds may
        # legitimately cite nothing — a brief can be all model numbers.
        if @kind == :poll_reaction && integers.empty? && @citable_poll_ids.any?
          errors << "cited_poll_ids is empty; a poll reaction must cite at least one of #{@citable_poll_ids.inspect}"
        end

        errors
      end

      def string(field)
        value = @data[field.to_s]
        value.is_a?(String) ? value.strip : nil
      end
  end
end
