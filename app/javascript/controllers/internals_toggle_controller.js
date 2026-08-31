import { Controller } from "@hotwired/stimulus"

// The site-wide partisan-internals switch. State lives in three places, by
// design, and this controller is the only writer of any of them:
//
//   html[data-internals]   what the CSS keys visibility off (and what the
//                          chart controllers read on re-render)
//   localStorage           the reader's remembered preference
//   the #internals=on hash a shareable link's override — a fragment rather
//                          than a query param, because a query string would
//                          split the edge cache and a cookie would break it
//
// The hash wins over storage on load (a shared link should show what the
// sharer saw), storage wins over the default. Everything the toggle changes
// is already in the page — both variants render server-side — so flipping
// is instant: swap the attribute, tell the charts, done. No numbers are
// ever computed client-side.
const STORAGE_KEY = "pol-internals"
const HASH_ON = "internals=on"

export default class extends Controller {
  static targets = ["switch"]

  connect() {
    this.apply(this.initialState(), { writeHash: false })
  }

  toggle() {
    this.apply(this.switchTarget.checked, { writeHash: true })
  }

  initialState() {
    if (window.location.hash.includes(HASH_ON)) return true

    try {
      return localStorage.getItem(STORAGE_KEY) === "on"
    } catch {
      return false
    }
  }

  apply(on, { writeHash }) {
    document.documentElement.dataset.internals = on ? "on" : "off"
    if (this.hasSwitchTarget) this.switchTarget.checked = on

    try {
      localStorage.setItem(STORAGE_KEY, on ? "on" : "off")
    } catch {
      // A blocked store just means the preference won't survive the visit.
    }

    if (writeHash) {
      const url = new URL(window.location)
      url.hash = on ? HASH_ON : ""
      history.replaceState(null, "", url)
    }

    window.dispatchEvent(new CustomEvent("internals:changed", { detail: { on } }))
  }
}
