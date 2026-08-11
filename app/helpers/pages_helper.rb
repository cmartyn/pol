module PagesHelper
  SECTION_TITLE = {
    averaging: "Poll averaging",
    blend: "Blending polls with fundamentals",
    fundamentals: "Fundamentals — partisan lean & national baselines",
    error_model: "Error model — how much uncertainty each draw carries",
    chambers: "Chamber control rules",
    simulation: "Simulation",
    election: "Election date",
    newsroom: "Newsroom (Phase 5)",
    scrape: "Data collection",
    site: "Site display rules"
  }.freeze

  def section_title(key)
    SECTION_TITLE.fetch(key, key.to_s.titleize)
  end

  # A parameter value formatted plainly: Pol::Params carries only scalars
  # (numbers, strings, booleans, nil), never anything a view needs to
  # recurse into.
  def param_value(value)
    case value
    when nil then "not yet set"
    when Float then format("%g", value)
    when true then "yes"
    when false then "no"
    else value.to_s
    end
  end

  # A citation rendered as a link when it looks like a URL, plain text (a
  # BUILD_NOTES pointer, say) otherwise.
  def citation_link(citation)
    citation.start_with?("http://", "https://") ? link_to(citation, citation, class: "text-amber-700 hover:text-amber-800", rel: "nofollow noopener") : citation
  end
end
