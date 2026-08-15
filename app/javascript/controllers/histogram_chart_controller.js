import { Controller } from "@hotwired/stimulus"
import { createTooltip } from "charts/tooltip"

// Interactivity for the server-rendered seat histogram
// (races/_seat_histogram.html.erb). The partial serves the bars and every
// human-readable string as data-* attributes on each rect; this controller
// only does geometry — which slot is under the pointer, where the hovered
// bar sits — and never composes prose (the payload carries the words, the
// JS carries the geometry).
//
// The pointer maps to a bin by slot arithmetic over the whole strip rather
// than per-rect hit testing: House bars can be a pixel wide, and the strip
// being one continuous hit target is what makes them reachable at all.
export default class extends Controller {
  connect() {
    this.svg = this.element.querySelector("svg")
    this.rects = this.svg ? Array.from(this.svg.querySelectorAll("rect[data-seats]")) : []
    if (this.rects.length === 0) return // the "No simulation yet" state serves no rects

    this.tooltip = createTooltip(this.element)
    this.activeIndex = null

    // Where keyboard focus lands first: the tallest bar. (The bin nearest
    // the mean would be marginally truer, but the mode reads the same and
    // is already sitting in the served geometry.)
    this.modalIndex = this.rects.reduce(
      (best, rect, index) => barHeight(rect) > barHeight(this.rects[best]) ? index : best, 0
    )

    this.onPointer = (event) => this.showBin(this.indexAtPointer(event))
    this.onPointerLeave = (event) => {
      // A touch pointer "leaves" the instant the finger lifts, which would
      // hide the readout a tap just opened — leave it up for touch; tapping
      // away blurs the wrapper and clears it there instead.
      if (event.pointerType !== "mouse") return
      this.clear()
    }
    this.onKeydown = (event) => this.handleKeydown(event)
    this.onFocus = () => {
      // Clicking the strip focuses the wrapper after pointerdown already
      // picked a bin — only seed the modal bin on a bare (keyboard) focus.
      if (this.activeIndex === null) this.showBin(this.modalIndex)
    }
    this.onBlur = () => this.clear()

    this.svg.addEventListener("pointermove", this.onPointer)
    this.svg.addEventListener("pointerdown", this.onPointer)
    this.svg.addEventListener("pointerleave", this.onPointerLeave)
    this.element.addEventListener("keydown", this.onKeydown)
    this.element.addEventListener("focus", this.onFocus)
    this.element.addEventListener("blur", this.onBlur)
  }

  disconnect() {
    if (!this.tooltip) return // connect bailed on the empty state

    this.clear() // erase the inline highlight so Turbo's page cache snapshots clean bars
    this.svg.removeEventListener("pointermove", this.onPointer)
    this.svg.removeEventListener("pointerdown", this.onPointer)
    this.svg.removeEventListener("pointerleave", this.onPointerLeave)
    this.element.removeEventListener("keydown", this.onKeydown)
    this.element.removeEventListener("focus", this.onFocus)
    this.element.removeEventListener("blur", this.onBlur)
    this.tooltip.destroy()
    this.tooltip = null
  }

  // offsetX is measured against whichever child the pointer happens to be
  // over (a rect, a line), so the slot fraction comes from clientX against
  // the svg's own box instead.
  indexAtPointer(event) {
    const box = this.svg.getBoundingClientRect()
    const fraction = (event.clientX - box.left) / box.width
    return Math.max(0, Math.min(this.rects.length - 1, Math.floor(fraction * this.rects.length)))
  }

  showBin(index) {
    if (index === this.activeIndex) return

    this.unhighlight()
    this.activeIndex = index
    const rect = this.rects[index]

    // One darker step of the bar's own hue (blue-600 -> blue-800,
    // slate-300 -> slate-400), inline so unhover can simply erase it.
    // No transition — the bars are too narrow for a fade to read.
    rect.style.fill = rect.classList.contains("fill-blue-600") ? "#1e40af" : "#94a3b8"

    const containerBox = this.element.getBoundingClientRect()
    const barBox = rect.getBoundingClientRect()
    this.tooltip.show(
      barBox.left + barBox.width / 2 - containerBox.left,
      barBox.top - containerBox.top,
      {
        header: rect.dataset.seatsLabel,
        rows: [
          { value: rect.dataset.shareLabel, label: "of simulations" },
          { value: rect.dataset.controlLabel }
        ]
      }
    )
  }

  handleKeydown(event) {
    if (event.altKey || event.ctrlKey || event.metaKey) return // Alt+Left is the browser's Back

    const last = this.rects.length - 1
    const from = this.activeIndex === null ? this.modalIndex : this.activeIndex
    switch (event.key) {
      case "ArrowLeft": this.showBin(Math.max(0, from - 1)); break
      case "ArrowRight": this.showBin(Math.min(last, from + 1)); break
      case "Home": this.showBin(0); break
      case "End": this.showBin(last); break
      case "Escape": this.clear(); return
      default: return
    }
    event.preventDefault() // arrows/Home/End scroll the page otherwise
  }

  unhighlight() {
    if (this.activeIndex === null) return
    this.rects[this.activeIndex].style.fill = ""
  }

  clear() {
    this.unhighlight()
    this.activeIndex = null
    this.tooltip.hide()
  }
}

function barHeight(rect) {
  return parseFloat(rect.getAttribute("height")) || 0
}
