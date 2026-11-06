import { Controller } from "@hotwired/stimulus"

// The joke's personality lives here; swing is a fraction of the dial's arc.
const ANXIETY_LEVELS = [
  { label: "Touching grass", swing: 0, speed: 0 },
  { label: "Just checking", swing: 0.025, speed: 1.2 },
  { label: "One more refresh", swing: 0.06, speed: 2 },
  { label: "Pacing the kitchen", swing: 0.14, speed: 3.5 },
  { label: "I am the needle", swing: 0.3, speed: 5 }
]

export default class extends Controller {
  static targets = ["content", "connection", "anxietyPanel", "anxietyInput", "anxietyLabel", "anxietyNote", "anxietyBadge", "needle"]
  static values = { url: String, revision: String }

  connect() {
    this.active = true
    this.needles = new Set(this.needleTargets)
    this.motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.onMotionPreference = () => this.updateAnxiety()
    this.motionPreference.addEventListener("change", this.onMotionPreference)
    this.anxietyLevel = 0
    try {
      this.anxietyLevel = this.validLevel(sessionStorage.getItem("election-night-anxiety"))
    } catch { /* The joke still works when browser storage is unavailable. */ }
    this.anxietyPanelTarget.hidden = false
    this.updateAnxiety()
    if (this.hasUrlValue) this.timer = setInterval(() => this.refresh(), 30000)
    this.onVisibility = () => {
      this.updateAnxiety()
      if (this.hasUrlValue && !document.hidden) this.refresh()
    }
    document.addEventListener("visibilitychange", this.onVisibility)
  }

  disconnect() {
    this.active = false
    clearInterval(this.timer)
    this.request?.abort()
    this.stopWiggle()
    this.motionPreference.removeEventListener("change", this.onMotionPreference)
    document.removeEventListener("visibilitychange", this.onVisibility)
  }

  needleTargetConnected(needle) {
    this.needles ||= new Set()
    this.needles.add(needle)
  }

  needleTargetDisconnected(needle) {
    this.needles?.delete(needle)
  }

  anxietyBadgeTargetConnected(badge) {
    badge.hidden = !this.wiggleAllowed()
  }

  changeAnxiety() {
    this.anxietyLevel = this.validLevel(this.anxietyInputTarget.value)
    this.saveAnxiety()
    this.updateAnxiety()
  }

  calmDown() {
    this.anxietyLevel = 0
    this.saveAnxiety()
    this.updateAnxiety()
  }

  validLevel(value) {
    const level = Number(value)
    return Number.isInteger(level) && level >= 0 && level < ANXIETY_LEVELS.length ? level : 0
  }

  saveAnxiety() {
    try {
      sessionStorage.setItem("election-night-anxiety", this.anxietyLevel)
    } catch { /* No persistence is needed to use the control. */ }
  }

  wiggleAllowed() {
    return this.active && this.anxietyLevel > 0 && !this.motionPreference?.matches && !document.hidden
  }

  updateAnxiety() {
    const profile = ANXIETY_LEVELS[this.anxietyLevel]
    this.anxietyInputTarget.value = this.anxietyLevel
    this.anxietyInputTarget.setAttribute("aria-valuetext", profile.label)
    this.anxietyLabelTarget.textContent = profile.label
    const reduced = this.anxietyLevel > 0 && this.motionPreference.matches
    this.anxietyNoteTarget.hidden = !reduced
    this.anxietyNoteTarget.textContent = reduced ? "Your reduced-motion setting is on. The needles are taking a breath." : ""
    this.anxietyBadgeTargets.forEach(badge => { badge.hidden = !this.wiggleAllowed() })
    this.stopWiggle()
    if (this.wiggleAllowed()) this.animationFrame = requestAnimationFrame(time => this.wiggle(time))
  }

  stopWiggle() {
    cancelAnimationFrame(this.animationFrame)
    this.animationFrame = null
    this.needles?.forEach(needle => this.positionNeedle(needle, Number(needle.dataset.probability)))
  }

  positionNeedle(needle, probability) {
    if (!Number.isFinite(probability)) return
    const angle = Math.PI * (1 - Math.max(0, Math.min(1, probability)))
    needle.setAttribute("x2", (180 + 132 * Math.cos(angle)).toFixed(2))
    needle.setAttribute("y2", (164 - 132 * Math.sin(angle)).toFixed(2))
  }

  wiggle(time) {
    if (!this.wiggleAllowed()) return
    const { swing, speed } = ANXIETY_LEVELS[this.anxietyLevel]
    let index = 0
    this.needles.forEach(needle => {
      const phase = time / 1000 * speed + index++ * 1.9
      const wave = 0.65 * Math.sin(phase) + 0.25 * Math.sin(phase * 2.3) + 0.1 * Math.sin(phase * 4.7)
      this.positionNeedle(needle, Number(needle.dataset.probability) + swing * wave)
    })
    this.animationFrame = requestAnimationFrame(nextTime => this.wiggle(nextTime))
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
        // Marked as a background request so RailsMind does not count the
        // refresh as another page view.
        const page = await fetch(window.location.pathname, { cache: "no-store", signal: this.request.signal, headers: { Accept: "text/html", "X-Requested-With": "XMLHttpRequest" } })
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
