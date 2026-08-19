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
end
