# Parses config/model_params.yml's own comments once per process, pulling
# out every `# citation: ...` line and associating it with the key it
# precedes. The methodology page renders every Pol::Params value next to its
# citation here, if one exists — this is the only path from a number the
# model uses to the source that justified it, so the page can truthfully
# claim "every parameter, with its citation where one exists" without a
# second, hand-maintained copy of the same information drifting out of sync
# with the YAML.
#
# The file has exactly two levels of nesting throughout — a top-level
# section ("error_model:") and, indented two spaces under it, scalar
# "key: value" pairs — so the parser only needs to track the current section
# and a run of pending citation lines. A `# citation:` line is captured; any
# other comment or blank line is skipped without disturbing what's already
# pending (so a paragraph of prose above the citation lines, or two citation
# lines in a row, both work); anything else resets the pending list.
module Site
  class ParamCitations
    CONFIG_PATH = Rails.root.join("config", "model_params.yml")
    # Comments and citations sit indented under their section, so both of
    # these allow (any amount of) leading whitespace; only a *section*
    # header is required to start at column 0, and a *key* is required to
    # sit at exactly 2 spaces — that's what distinguishes them from each
    # other and from deeper YAML structure.
    CITATION_LINE = /\A\s*#\s*citation:\s*(.+)\z/
    COMMENT_OR_BLANK_LINE = /\A\s*(?:#.*)?\z/
    SECTION_LINE = /\A(\w[\w-]*):/
    KEY_LINE = /\A {2}(\w[\w-]*):/

    class << self
      # Site::ParamCitations.for(:error_model, :sigma_national)
      #   => ["https://aapor.org/...", "https://aapor.org/..."]
      # Empty array when the key has no citation (a valid, common case).
      def for(*path)
        table.fetch(path, [])
      end

      def table
        @table ||= parse
      end

      # Intended for tests: re-reads the file into a new memoized table.
      def reload!
        @table = nil
        table
      end

      private
        def parse
          citations = {}
          section = nil
          pending = []

          CONFIG_PATH.each_line do |raw_line|
            line = raw_line.chomp # \z below is end-of-string; without chomping it'd never match

            if (match = line.match(CITATION_LINE))
              pending << match[1].strip
            elsif line.match?(COMMENT_OR_BLANK_LINE)
              next
            elsif (match = line.match(SECTION_LINE))
              section = match[1].to_sym
              pending = []
            elsif (match = line.match(KEY_LINE))
              citations[[ section, match[1].to_sym ]] = pending.dup if pending.any?
              pending = []
            else
              pending = []
            end
          end

          citations
        end
    end
  end
end
