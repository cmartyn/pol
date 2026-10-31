import { Controller } from "@hotwired/stimulus"

// The site-wide partisan-internals switch. State lives in three places, by
// design, and this controller is the only writer of any of them:
//
//   html[data-internals]   what the CSS keys visibility off (and what the
//                          chart controllers read on re-render)
//   sessionStorage         the reader's choice for this visit. Not
//                          localStorage: a variant the site doesn't publish
//                          should not greet a reader who comes back days
//                          later and has forgotten turning it on
//   the #internals=on hash a shareable link's override — a fragment rather
//                          than a query param, because a query string would
//                          split the edge cache and a cookie would break it
//
// The hash wins over storage on load (a shared link should show what the
// sharer saw), storage wins over the default. Everything the toggle changes
// is already in the page — both variants render server-side — so flipping
// is instant: swap the attribute, tell the charts, done. No numbers are
// ever computed client-side.
//
// Mounted on <body> so a page's "Turn off" (shared/_internals_marker) can
// reach it; the switch itself is in the header.
const STORAGE_KEY = "pol-internals"
const HASH_ON = "internals=on"

export default class extends Controller {
  static targets = ["switch", "status"]

  connect() {
    this.apply(this.initialState(), { writeHash: false })
  }

  toggle() {
    this.apply(this.switchTarget.checked, { writeHash: true })
    this.announce()
  }

  turnOff() {
    this.apply(false, { writeHash: true })
    this.announce()
  }

  initialState() {
    if (window.location.hash.includes(HASH_ON)) return true

    try {
      return sessionStorage.getItem(STORAGE_KEY) === "on"
    } catch {
      return false
    }
  }

  apply(on, { writeHash }) {
    document.documentElement.dataset.internals = on ? "on" : "off"
    if (this.hasSwitchTarget) this.switchTarget.checked = on

    try {
      sessionStorage.setItem(STORAGE_KEY, on ? "on" : "off")
    } catch {
      // A blocked store just means the choice won't follow the reader to the next page.
    }

    if (writeHash) {
      const url = new URL(window.location)
      url.hash = on ? HASH_ON : ""
      // Keep Turbo's state on the entry: without its restoration id, Back to
      // this page changes the URL and leaves the next page on screen.
      history.replaceState(history.state, "", url)
    }

    window.dispatchEvent(new CustomEvent("internals:changed", { detail: { on } }))
  }

  // Every figure on the page just changed under the reader. The switch's
  // own "checked" doesn't say that.
  announce() {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = document.documentElement.dataset.internals === "on"
      ? "Partisan internals on. Figures include partisan-sponsored polls, adjusted."
      : "Partisan internals off. Showing the published forecast."
  }
}
