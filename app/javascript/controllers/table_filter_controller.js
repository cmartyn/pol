import { Controller } from "@hotwired/stimulus"

// A plain client-side text filter for the /house table (435 rows — a real
// database search felt like overkill for "type a state or district"). Each
// row carries its own lowercase, pre-joined search text via data-search;
// the query is split on whitespace so "ny 17" and "17 ny" both match. The
// table stays a single server-rendered fragment for every search state —
// this only toggles row visibility, it never re-fetches or re-sorts.
export default class extends Controller {
  static targets = ["input", "row", "count", "noResults"]

  filter() {
    const terms = this.inputTarget.value.trim().toLowerCase().split(/\s+/).filter(Boolean)
    let visible = 0

    this.rowTargets.forEach((row) => {
      const haystack = row.dataset.search || ""
      const matches = terms.every((term) => haystack.includes(term))
      row.hidden = !matches
      if (matches) visible += 1
    })

    if (this.hasCountTarget) this.countTarget.textContent = visible
    if (this.hasNoResultsTarget) this.noResultsTarget.hidden = visible !== 0
  }
}
