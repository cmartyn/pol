import { Controller } from "@hotwired/stimulus"

// A plain client-side text filter for the /senate and /house tables (435
// rows on House — a real database search felt like overkill for "type a
// state or district"). Each row carries its own lowercase, pre-joined
// search text via data-search; the query is split on whitespace so "ny 17"
// and "17 ny" both match. The table stays a single server-rendered fragment
// for every search state — this only toggles row visibility, it never
// re-fetches or re-sorts.
//
// Sorting is a full page reload (plain query-param links — see
// RacesHelper#sort_header), so a sort click would otherwise silently drop
// whatever the reader just typed here. Two things close that gap: connect()
// restores the input (and re-applies the filter) from a ?q= the reload
// carried forward, and every keystroke rewrites each sort link's ?q= to the
// reader's *current* text before it's ever sent anywhere — so even the very
// first sort click after typing, before any round trip, carries it. Both
// have to happen client-side: baking params[:q] into a sort link inside the
// cached table fragment would leak whichever reader's search happened to
// populate that cache entry into every other reader's links.
//
// That reload can be slow, and until it lands the old table and its old
// arrow stay on screen. sort() marks the table busy on the click itself, and
// holds back a repeat click on the same pending link: Turbo would otherwise
// abort the request in flight and start it again on every click, so a reader
// who clicks again because nothing seems to happen only makes the wait
// longer.
export default class extends Controller {
  static targets = [ "input", "row", "count", "noResults", "sortLink", "status" ]

  connect() {
    this.clearPending() // a Turbo cache snapshot can carry the busy state back in

    if (!this.hasInputTarget) return // the no-rows empty state renders no search box at all

    const q = new URLSearchParams(window.location.search).get("q")
    if (q) this.inputTarget.value = q
    this.filter()
  }

  filter() {
    const raw = this.inputTarget.value.trim()
    const terms = raw.toLowerCase().split(/\s+/).filter(Boolean)
    let visible = 0

    this.rowTargets.forEach((row) => {
      const haystack = row.dataset.search || ""
      const matches = terms.every((term) => haystack.includes(term))
      row.hidden = !matches
      if (matches) visible += 1
    })

    if (this.hasCountTarget) this.countTarget.textContent = visible
    if (this.hasNoResultsTarget) this.noResultsTarget.hidden = visible !== 0

    this.syncSortLinks(raw)
  }

  // Keeps every sort-header link's ?q= equal to whatever is in the box
  // right now, so a sort click never reloads into an unfiltered table.
  syncSortLinks(query) {
    this.sortLinkTargets.forEach((link) => {
      const url = new URL(link.href)
      if (query) {
        url.searchParams.set("q", query)
      } else {
        url.searchParams.delete("q")
      }
      link.href = url.toString()
    })
  }

  sort(event) {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return // a new tab or window, not this page

    const href = event.currentTarget.href
    if (href === this.pendingHref) {
      event.preventDefault()
      return
    }

    this.pendingHref = href
    this.element.setAttribute("aria-busy", "true")
    if (this.hasStatusTarget) this.statusTarget.textContent = "Sorting the table…"
  }

  clearPending() {
    this.pendingHref = null
    this.element.removeAttribute("aria-busy")
    if (this.hasStatusTarget) this.statusTarget.textContent = ""
  }
}
