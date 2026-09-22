import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { createTooltip } from "charts/tooltip"
import { partyColor } from "charts/theme"

// Interactivity for the server-rendered maps (races/_map.html.erb). Every
// word arrives in the map's tips JSON. This controller only works out which
// shape the pointer or keyboard means and places the readout there (the
// payload carries the words, the JS carries the geometry).
//
// A district can be a pixel wide on the national House map, so when the
// pointer isn't directly over a shape it snaps to the nearest shape center
// within SNAP_PX — for the same reason the histogram hit-tests by slot.
const SNAP_PX = 24

export default class extends Controller {
  static targets = ["shape", "tips"]

  connect() {
    this.svg = this.element.querySelector("svg")
    if (!this.svg || this.shapeTargets.length === 0 || !this.hasTipsTarget) return

    this.tips = JSON.parse(this.tipsTarget.textContent)
    this.tooltip = createTooltip(this.element)
    this.activeIndex = null

    this.onPointer = (event) => this.showAtPointer(event)
    this.onPointerLeave = (event) => {
      // A touch pointer "leaves" as the finger lifts; the tap that follows
      // opens the race, so only a mouse clears on leave.
      if (event.pointerType === "mouse") this.clear()
    }
    this.onClick = (event) => this.followLink(event)
    this.onKeydown = (event) => this.handleKeydown(event)
    this.onFocus = () => {
      if (this.activeIndex === null && this.element.matches(":focus-visible")) this.show(0)
    }
    this.onBlur = () => this.clear()
    this.onVariantChange = () => {
      if (this.activeIndex !== null) this.render(this.activeIndex)
    }

    this.svg.addEventListener("pointermove", this.onPointer)
    this.svg.addEventListener("pointerleave", this.onPointerLeave)
    this.svg.addEventListener("click", this.onClick)
    this.element.addEventListener("keydown", this.onKeydown)
    this.element.addEventListener("focus", this.onFocus)
    this.element.addEventListener("blur", this.onBlur)
    window.addEventListener("internals:changed", this.onVariantChange)
  }

  disconnect() {
    if (!this.tooltip) return // connect bailed: a map with nothing to hover

    this.clear() // so Turbo's page-cache snapshot has no highlighted shape
    this.svg.removeEventListener("pointermove", this.onPointer)
    this.svg.removeEventListener("pointerleave", this.onPointerLeave)
    this.svg.removeEventListener("click", this.onClick)
    this.element.removeEventListener("keydown", this.onKeydown)
    this.element.removeEventListener("focus", this.onFocus)
    this.element.removeEventListener("blur", this.onBlur)
    window.removeEventListener("internals:changed", this.onVariantChange)
    this.tooltip.destroy()
    this.tooltip = null
  }

  // turbo-rails reads link.href as a string, but an SVG <a>'s href is an
  // SVGAnimatedString, so Turbo's own click handler throws on these links and
  // the browser falls back to a full page load. Visiting here and preventing
  // the default means Turbo's handler (on window, later in the bubble) skips.
  followLink(event) {
    if (event.defaultPrevented || event.button !== 0 || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return

    const link = event.target.closest("[data-map-chart-target~='shape']")
    if (!link) return

    event.preventDefault()
    Turbo.visit(link.getAttribute("href"))
  }

  showAtPointer(event) {
    const overShape = event.target.closest(".map-shape")
    if (overShape) {
      const direct = overShape.closest("[data-map-chart-target~='shape']")
      if (direct) {
        this.show(this.shapeTargets.indexOf(direct))
        return
      }
      if (event.pointerType === "mouse") this.clear()
      return
    }

    const index = this.nearestIndex(event.clientX, event.clientY)
    if (index === null || index < 0) {
      if (event.pointerType === "mouse") this.clear()
      return
    }
    this.show(index)
  }

  nearestIndex(clientX, clientY) {
    const matrix = this.svg.getScreenCTM()
    if (!matrix) return null

    let best = null
    let bestDistance = SNAP_PX
    this.shapeTargets.forEach((shape, index) => {
      const point = screenPoint(shape, matrix)
      const distance = Math.hypot(point.x - clientX, point.y - clientY)
      if (distance < bestDistance) {
        best = index
        bestDistance = distance
      }
    })
    return best
  }

  show(index) {
    if (index === this.activeIndex) return

    this.unhighlight()
    this.activeIndex = index
    this.shapeTargets[index].setAttribute("data-active", "")
    this.render(index)
  }

  render(index) {
    const shape = this.shapeTargets[index]
    const variant = document.documentElement.dataset.internals === "on" ? "incl_internals" : "excl_internals"
    const tip = this.tips[shape.dataset.key]?.[variant]
    const matrix = this.svg.getScreenCTM()
    if (!tip || !matrix) return

    const point = screenPoint(shape, matrix)
    const box = this.element.getBoundingClientRect()
    this.tooltip.show(point.x - box.left, point.y - box.top, {
      header: tip.header,
      subheader: tip.subheader,
      rows: tip.rows.map((row) => ({
        key: row.swatch ? partyColor(row.party) : null,
        value: row.value,
        valueColor: row.party ? partyColor(row.party) : null,
        label: row.label
      })),
      footer: tip.footer
    })
  }

  handleKeydown(event) {
    if (event.altKey || event.ctrlKey || event.metaKey) return // Alt+Left is the browser's Back

    const last = this.shapeTargets.length - 1
    const from = this.activeIndex ?? -1
    switch (event.key) {
      case "ArrowLeft": this.show(Math.max(0, from - 1)); break
      case "ArrowRight": this.show(Math.min(last, from + 1)); break
      case "Home": this.show(0); break
      case "End": this.show(last); break
      case "Enter":
        if (this.activeIndex === null) return
        Turbo.visit(this.shapeTargets[this.activeIndex].getAttribute("href"))
        break
      case "Escape": this.clear(); return
      default: return
    }
    event.preventDefault() // arrows/Home/End scroll the page otherwise
  }

  unhighlight() {
    if (this.activeIndex === null) return
    this.shapeTargets[this.activeIndex].removeAttribute("data-active")
  }

  clear() {
    this.unhighlight()
    this.activeIndex = null
    this.tooltip?.hide()
  }
}

// A shape's center (viewBox units, from data-cx/-cy) in client pixels.
function screenPoint(shape, matrix) {
  const x = parseFloat(shape.dataset.cx)
  const y = parseFloat(shape.dataset.cy)
  return { x: matrix.a * x + matrix.c * y + matrix.e, y: matrix.b * x + matrix.d * y + matrix.f }
}
