module PagesHelper
  SECTION_TITLE = {
    averaging: "Poll averaging",
    house_effects: "Pollster house effects",
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
  #
  # A URL citation may carry a trailing note — "https://openrouter.ai/api/v1/
  # models (retrieved 2026-08-11)" is one in config/model_params.yml — and the
  # note is not part of the address. Linking the whole string produced an href
  # with a space in it, which browsers percent-encode into a 404: a broken
  # source link on the one page whose entire promise is that every number here
  # can be checked. Only the first whitespace-delimited token is the URL.
  def citation_link(citation)
    return citation unless citation.start_with?("http://", "https://")

    url, note = citation.split(/\s+/, 2)
    link = link_to(url, url, class: "text-amber-700 hover:text-amber-800", rel: "nofollow noopener")
    note.present? ? safe_join([ link, " ", note ]) : link
  end
end
