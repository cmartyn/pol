module ApplicationHelper
  def canonical_url
    URI::HTTPS.build(
      host: ENV.fetch("CANONICAL_HOST", request.host),
      path: request.path
    ).to_s
  end
  # A primary-nav link that marks itself current — aria-current is what
  # assistive tech reads; the underline is what everyone else sees.
  def nav_link(label, path, quiet: false)
    current = current_page?(path)
    tone = if current
      "text-slate-900 underline decoration-amber-500 decoration-2 underline-offset-4"
    elsif quiet
      "text-slate-500 hover:text-slate-900"
    else
      "text-slate-700 hover:text-slate-900"
    end
    classes = "inline-flex min-h-11 items-center rounded px-2 py-1 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-amber-600 #{tone}"

    link_to label, path, class: classes, aria: { current: current ? "page" : nil }
  end

  # Phone and tablet public pages. Session, password, unsubscribe, and
  # email-preferences stay documents: they keep the stacking header and
  # do not get the bottom bar.
  def app_shell?
    %w[sessions passwords unsubscribes subscription_preferences].exclude?(controller_name)
  end

  # Which bottom-bar item is the page the reader is on. A race keeps its
  # chamber current, so the bar still says where that screen was opened from.
  def shell_section
    case controller_name
    when "home"
      :dashboard
    when "races"
      case action_name
      when "senate" then :senate
      when "house" then :house
      when "show"
        return unless defined?(@race) && @race

        if @race.house?
          :house
        elsif @race.senate?
          :senate
        end
      end
    when "polls", "pollsters"
      :more
    when "pages"
      :more if %w[methodology about privacy].include?(action_name)
    end
  end

  def shell_tab_classes(current)
    tone = current ? "text-slate-900 underline decoration-amber-500 decoration-2 underline-offset-4" : "text-slate-700 hover:text-slate-900"
    "inline-flex min-h-12 w-full items-center justify-center px-1 text-sm font-medium focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-amber-600 #{tone}"
  end

  def shell_action_classes(current)
    tone = current ? "text-slate-900 underline decoration-amber-500 decoration-2 underline-offset-4" : "text-slate-700 hover:text-slate-900"
    "inline-flex min-h-11 items-center rounded px-2 text-sm font-medium focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-amber-600 xl:hidden #{tone}"
  end

  def shell_sheet_link(label, path)
    current = current_page?(path)
    tone = current ? "text-slate-900 underline decoration-amber-500 decoration-2 underline-offset-4" : "text-slate-800"
    classes = "flex min-h-12 items-center text-base font-medium focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-amber-600 #{tone}"

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
