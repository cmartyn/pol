module ApplicationHelper
  def canonical_url
    URI::HTTPS.build(
      host: ENV.fetch("CANONICAL_HOST", request.host),
      path: request.path
    ).to_s
  end
  # A primary-nav link that marks itself current — aria-current is what
  # assistive tech reads; the underline is what everyone else sees.
  def nav_link(label, path)
    current = current_page?(path)
    classes = current ? "rounded px-2 py-1 text-slate-900 underline decoration-amber-500 decoration-2 underline-offset-4" : "rounded px-2 py-1 text-slate-600 hover:text-slate-900"

    link_to label, path, class: classes, aria: { current: current ? "page" : nil }
  end

  # The succeeded run every published figure on this site is "as of", for the
  # header's freshness stamp. The layout renders on every page — including
  # ones whose controller never looks a run up (dispatches, methodology,
  # about) — so this needs a lookup of its own, but where a controller
  # already set @latest_run (the dashboard, the chamber tables) it reuses
  # that rather than paying for the same query twice.
  #
  # `defined?` rather than `||=`: a site with no completed run yet
  # legitimately has nil here, and ||= would re-run that query on every
  # call instead of remembering the answer.
  def latest_model_run
    return @latest_run if defined?(@latest_run)

    @latest_run = ModelRun.succeeded.latest.first
  end

  # poll.source_url is stored free-form (Poll validates only its presence —
  # the feed trusts its own links, but manual entry and CSV import both
  # accept whatever an editor typed). Rendering it straight into link_to's
  # href is exactly the shape Brakeman's LinkToHref check warns about: a
  # stored value, not a literal, used as a URL — javascript:/data: schemes
  # render fine and execute on click. Every view that links to a source, on
  # the public site and in admin, goes through here instead of calling
  # link_to on the raw column, so a non-http(s) value renders as inert text
  # rather than a clickable href built from it.
  def safe_external_link(url, text = url, **html_options)
    if url.to_s.match?(%r{\Ahttps?://}i)
      link_to text, url, **html_options
    else
      content_tag(:span, text, class: html_options[:class], data: html_options[:data])
    end
  end
end
