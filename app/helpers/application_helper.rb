module ApplicationHelper
  # A primary-nav link that marks itself current — aria-current is what
  # assistive tech reads; the underline is what everyone else sees.
  def nav_link(label, path)
    current = current_page?(path)
    classes = current ? "rounded px-2 py-1 text-slate-900 underline decoration-amber-500 decoration-2 underline-offset-4" : "rounded px-2 py-1 text-slate-600 hover:text-slate-900"

    link_to label, path, class: classes, aria: { current: current ? "page" : nil }
  end
end
