# Shared chrome for every /admin page — the layout-wide counterpart to
# ApplicationHelper. Per-section helpers (Admin::PollsHelper etc.) hold
# section-specific rendering; this is only what app/views/layouts/admin.html.erb
# itself needs.
module AdminHelper
  # A primary-nav link in the admin header that marks itself current, dark
  # chrome instead of ApplicationHelper#nav_link's light one — the admin
  # cockpit is deliberately styled distinctly from the public site so it's
  # never ambiguous which one is on screen.
  def admin_nav_link(label, path)
    current = current_page?(path)
    classes = current ? "rounded px-2 py-1 font-semibold text-white bg-slate-800" : "rounded px-2 py-1 text-slate-300 hover:bg-slate-800 hover:text-white"

    link_to label, path, class: classes, aria: { current: current ? "page" : nil },
                          data: { testid: "admin-nav-#{label.parameterize}" }
  end
end
