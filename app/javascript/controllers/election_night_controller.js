import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "connection"]
  static values = { url: String, revision: String }

  connect() {
    this.active = true
    this.timer = setInterval(() => this.refresh(), 30000)
    this.onVisibility = () => { if (!document.hidden) this.refresh() }
    document.addEventListener("visibilitychange", this.onVisibility)
  }

  disconnect() {
    this.active = false
    clearInterval(this.timer)
    this.request?.abort()
    document.removeEventListener("visibilitychange", this.onVisibility)
  }

  async refresh() {
    if (this.busy || document.hidden || !this.active) return
    this.busy = true
    this.request = new AbortController()
    const timeout = setTimeout(() => this.request.abort(), 15000)
    try {
      const response = await fetch(this.urlValue, { cache: "no-store", signal: this.request.signal, headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error("Snapshot unavailable")
      const snapshot = await response.json()
      if (snapshot.revision !== this.revisionValue) {
        const page = await fetch(window.location.pathname, { cache: "no-store", signal: this.request.signal, headers: { Accept: "text/html" } })
        if (!page.ok) throw new Error("Page unavailable")
        const documentCopy = new DOMParser().parseFromString(await page.text(), "text/html")
        const next = documentCopy.querySelector('[data-election-night-target="content"]')
        if (!next || !this.active) throw new Error("Page unavailable")
        const openDetails = Array.from(this.contentTarget.querySelectorAll("details[open]")).map(element => element.id)
        const focusedDisclosure = this.contentTarget.contains(document.activeElement) ? document.activeElement.closest("details")?.id : null
        const scrollPosition = this.contentTarget.querySelector(".night-table-scroll")
        const tableScroll = scrollPosition ? [scrollPosition.scrollLeft, scrollPosition.scrollTop] : null
        this.contentTarget.replaceChildren(...Array.from(next.childNodes))
        openDetails.forEach(id => {
          const details = this.contentTarget.querySelector(`#${CSS.escape(id)}`)
          if (details) details.open = true
        })
        if (tableScroll) {
          const table = this.contentTarget.querySelector(".night-table-scroll")
          if (table) table.scrollTo(...tableScroll)
        }
        if (focusedDisclosure) this.contentTarget.querySelector(`#${CSS.escape(focusedDisclosure)} > summary`)?.focus({ preventScroll: true })
        this.revisionValue = next.dataset.revision
      }
      if (this.active) this.connectionTarget.hidden = true
    } catch (error) {
      if (this.active) {
        this.connectionTarget.textContent = "Connection interrupted. Showing the last available forecast; retrying automatically."
        this.connectionTarget.hidden = false
      }
    } finally {
      clearTimeout(timeout)
      this.busy = false
    }
  }
}
