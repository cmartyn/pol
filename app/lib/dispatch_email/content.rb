module DispatchEmail
  class Content
    EXCERPT_LIMIT = 900

    def self.excerpt(dispatch)
      paragraphs = dispatch.body_markdown.to_s.split(/\n{2,}/).map(&:strip).reject(&:blank?).first(2)
      text = paragraphs.join("\n\n")
      return text if text.length <= EXCERPT_LIMIT

      "#{text.first(EXCERPT_LIMIT).sub(/\s+\S*\z/, "")}…"
    end
  end
end
