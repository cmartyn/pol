import { Controller } from "@hotwired/stimulus"
import { select, pointer } from "d3-selection"
import { scaleLinear, scaleTime } from "d3-scale"
import { partyColor, AVERAGE, CHROME } from "charts/theme"
import { observeWidth, frame } from "charts/dimensions"
import { timeTicks } from "charts/time_ticks"
import { createTooltip } from "charts/tooltip"

// A race page's polls-over-time scatter: every poll at (field date, margin),
// colored by which side leads, plus the current weighted average as a dashed
// reference line. Data comes from Site::Charts::PollsScatter
// (app/lib/site/charts/polls_scatter.rb) via a sibling
// <script type="application/json"> tag, and that payload carries every
// human-readable string — margin labels, party letters, field-period
// datelines, sample descriptions, the "avg D+10.2" annotation. This
// controller only places prebuilt text and computes geometry, so
// Site::Format's conventions never grow a second JS implementation to
// drift from.
//
// The chart renders at the container's real pixel width (re-rendered on
// width change, see charts/dimensions.js) with fixed font sizes; the ERB's
// viewBox exists only to hold pre-JS space and is removed on first render.
// The controller's root element isn't rendered at all when the race has no
// polls — see races/_polls_scatter_chart.html.erb.
//
// Deliberately no tabindex/keyboard layer in the chart: the poll table
// directly below carries every value and source link, so the tooltip is an
// enhancement over information that is already reachable, never the only
// path to it.

const MARGIN = { top: 14, right: 76, bottom: 30, left: 52 }
const DOT_RADIUS = 4.5
const HOVER_DOT_RADIUS = 6.5
// Screen distance within which a point counts as "under" the pointer — a
// reader aims at a region, not a 9px dot.
const HOVER_RADIUS = 28
// Keeps the extreme points off the plot's own edge. The x domain runs from
// the oldest poll to the newest, so without this the first and last dots land
// at exactly 0 and innerWidth — which is precisely where the capture rect
// stops. Half of an edge dot's hover region then falls outside the only
// element listening for pointer events, and at a fractional layout position
// (a plot starting at x=124.5) the dot's own centre rounds to the wrong side
// of the boundary and the dot cannot be hovered at all. Insetting the range
// rather than padding the domain keeps the axis honest about the dates it
// covers; it only stops marks from being drawn on the boundary. Sized to the
// hovered dot's radius so the largest a dot ever draws still sits clear.
const EDGE_INSET = HOVER_DOT_RADIUS + 2

// Which view the internals toggle is showing (internals_toggle_controller
// owns the attribute). The payload's top-level average_* keys are the
// published view; the toggled-on view's line lives under payload.incl.
// Points are never filtered — an internal poll is visible in both views —
// but the published view draws it hollow: on the page, not in the math.
const internalsOn = () => document.documentElement.dataset.internals === "on"


export default class extends Controller {
  static targets = ["svg", "payload"]

  connect() {
    this.payload = JSON.parse(this.payloadTarget.textContent)
    this.points = this.payload.points.map((point) => ({ ...point, date: new Date(point.t) }))
    this.tooltip = createTooltip(this.element)
    this.hoverIndex = null
    this.armedIndex = null
    // click events lack pointerType in some engines; pointerdown never does,
    // so remember the last one seen and fall back to it.
    this.lastPointerType = "mouse"
    this.onInternals = () => { if (this.lastWidth) this.render(this.lastWidth) }
    window.addEventListener("internals:changed", this.onInternals)
    this.teardown = observeWidth(this.element, (width) => this.render(width))
  }

  disconnect() {
    if (this.teardown) this.teardown()
    if (this.tooltip) this.tooltip.destroy()
    window.removeEventListener("internals:changed", this.onInternals)
  }

  // The reference-line values for the view currently showing.
  activeAverage() {
    if (internalsOn() && this.payload.incl) return this.payload.incl

    return this.payload
  }

  render(containerWidth) {
    this.lastWidth = containerWidth
    const svg = select(this.svgTarget)
    svg.selectAll("*").remove()
    this.hoverIndex = null
    this.armedIndex = null
    this.tooltip.hide()
    if (this.points.length === 0) return

    const { width, height, margin, innerWidth, innerHeight } = frame(containerWidth, {
      margin: MARGIN, minHeight: 200, maxHeight: 280, heightRatio: 0.38
    })
    svg.attr("width", width).attr("height", height).attr("viewBox", null)

    const x = scaleTime().domain(paddedDateExtent(this.points)).range([EDGE_INSET, innerWidth - EDGE_INSET])

    // Symmetric domain so "Even" sits mid-chart and a lead either way reads
    // at the same scale; the average is included so its line can never leave
    // the plot.
    // Both views' averages are in the domain so toggling never rescales the
    // chart under the reader's pointer.
    const magnitudes = this.points.map((point) => Math.abs(point.margin))
    if (this.payload.average_margin !== null) magnitudes.push(Math.abs(this.payload.average_margin))
    if (this.payload.incl && this.payload.incl.average_margin !== null) magnitudes.push(Math.abs(this.payload.incl.average_margin))
    const average = this.activeAverage()
    const bound = Math.max(4, ...magnitudes) * 1.15
    const y = scaleLinear().domain([-bound, bound]).range([innerHeight, 0])

    const g = svg.append("g").attr("transform", `translate(${margin.left},${margin.top})`)

    // Y axis: party-anchored margin ticks — "D+10 / Even / R+10", letters
    // and colors from the payload, which is the fix for the party-blind
    // "+20/0/−10" axis (wrong on the races where side A isn't a Democrat).
    // The ≤6 rung matters: a close race (max |margin| ~4) gets a ~4.6 bound,
    // and without it the only tick between −5 and +5 is "Even" — one lonely
    // gridline on exactly the races readers squint at hardest.
    const step = bound <= 6 ? 2 : bound <= 12 ? 5 : bound <= 30 ? 10 : 20
    for (let value = -Math.floor(bound / step) * step; value <= bound; value += step) {
      const even = value === 0
      g.append("line")
        .attr("x1", 0).attr("x2", innerWidth)
        .attr("y1", y(value)).attr("y2", y(value))
        // The 0 gridline is slightly darker than the rest: it means "Even",
        // not just "a multiple of the tick step".
        .attr("stroke", even ? CHROME.baseline : CHROME.grid)
        .attr("stroke-width", 1)

      g.append("text")
        .attr("x", -8)
        .attr("y", y(value))
        .attr("text-anchor", "end")
        .attr("dominant-baseline", "central")
        .attr("font-size", CHROME.fontSize)
        .attr("font-weight", even ? 400 : 600)
        .attr("fill", even ? CHROME.axisText : partyColor(value > 0 ? this.payload.side_a_party : this.payload.side_b_party))
        .style("font-variant-numeric", "tabular-nums")
        .text(even ? "Even" : `${value > 0 ? this.payload.side_a_letter : this.payload.side_b_letter}+${Math.abs(value)}`)
    }

    // X axis: political-time ticks with the year anchored (charts/time_ticks
    // — never bare months across a year boundary, never clock times).
    g.append("line")
      .attr("x1", 0).attr("x2", innerWidth)
      .attr("y1", innerHeight).attr("y2", innerHeight)
      .attr("stroke", CHROME.baseline)
      .attr("stroke-width", 1)
    for (const tick of timeTicks(x, innerWidth)) {
      const tx = x(tick.date)
      g.append("line")
        .attr("x1", tx).attr("x2", tx)
        .attr("y1", innerHeight).attr("y2", innerHeight + 4)
        .attr("stroke", CHROME.baseline)
        .attr("stroke-width", 1)
      g.append("text")
        .attr("x", tx)
        .attr("y", innerHeight + 8)
        .attr("text-anchor", "middle")
        .attr("dominant-baseline", "hanging")
        .attr("font-size", CHROME.fontSize)
        .attr("fill", CHROME.axisText)
        .style("font-variant-numeric", "tabular-nums")
        .text(tick.label)
    }

    // The average reference line — dashed because it is a reference, the one
    // place dashing means something here. Drawn under the dots; its label
    // goes on top of them, further down.
    if (average.average_margin !== null) {
      g.append("line")
        .attr("x1", 0).attr("x2", innerWidth)
        .attr("y1", y(average.average_margin)).attr("y2", y(average.average_margin))
        .attr("stroke", AVERAGE.line)
        .attr("stroke-width", 1.5)
        .attr("stroke-dasharray", "4,3")
    }

    // Dots in their own layer: a hovered dot is raised within the layer so
    // its ring reads over neighbors, but never above the capture rect; the
    // layer is pointer-inert so hit-testing stays with the rect alone.
    this.dotNodes = g.append("g")
      .attr("pointer-events", "none")
      .selectAll(null)
      .data(this.points)
      .join("circle")
      .attr("cx", (point) => x(point.date))
      .attr("cy", (point) => y(point.margin))
      .attr("r", DOT_RADIUS)
      // An internal poll in the published view is on the chart but out of
      // the average — drawn hollow, its party color as a ring, so the dot
      // itself says which polls the dashed line is not made of.
      .attr("fill", (point) => point.internal && !internalsOn() ? "#ffffff" : partyColor(point.party))
      .attr("fill-opacity", (point) => point.internal && !internalsOn() ? 1 : 0.8)
      .attr("stroke", (point) => point.internal && !internalsOn() ? partyColor(point.party) : CHROME.ring)
      .attr("stroke-width", 1.5)
      .nodes()

    // The line's annotation lives in the right margin (so it cannot collide
    // with y ticks), clamped inside the plot's vertical bounds, with a halo
    // so dots crowding the right edge can't swallow it.
    if (average.average_label) {
      g.append("text")
        .attr("x", innerWidth + 6)
        .attr("y", Math.max(6, Math.min(innerHeight - 6, y(average.average_margin))))
        .attr("dominant-baseline", "central")
        .attr("font-size", CHROME.fontSize)
        .attr("font-weight", 600)
        .attr("fill", AVERAGE.text)
        .attr("paint-order", "stroke")
        .attr("stroke", CHROME.ring)
        .attr("stroke-width", 3)
        .attr("stroke-linejoin", "round")
        .style("font-variant-numeric", "tabular-nums")
        .text(average.average_label)
    }

    // One transparent rect over the whole plot owns every pointer event —
    // nearest-point snapping from anywhere in the plot beats pixel-hunting
    // 9px circles, especially on touch.
    this.positions = this.points.map((point) => ({ px: x(point.date), py: y(point.margin) }))
    this.plotMargin = margin
    this.captureRect = g.append("rect")
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "transparent")
      .on("pointerdown", (event) => { if (event.pointerType) this.lastPointerType = event.pointerType })
      .on("pointermove", (event) => this.pointerMoved(event))
      .on("pointerleave", (event) => this.pointerLeft(event))
      .on("click", (event) => this.clicked(event))
  }

  pointerMoved(event) {
    if (event.pointerType) this.lastPointerType = event.pointerType
    const index = this.nearestIndex(event)
    if (index === null) this.clearHover()
    else this.setHover(index)
  }

  // Touch fires pointerleave the instant a tap ends; honoring it would hide
  // the tooltip in the same frame the first tap showed it. A touch reader
  // dismisses by tapping empty plot instead.
  pointerLeft(event) {
    if (event.pointerType === "touch") return
    this.clearHover()
  }

  // Mouse: a click while a linked point is hovered opens its source. Touch
  // has no hover to preview with, so the first tap is the tooltip and only
  // a second tap on the same point follows the link.
  clicked(event) {
    const pointerType = event.pointerType || this.lastPointerType
    const index = this.nearestIndex(event)
    if (index === null) {
      this.clearHover()
      return
    }

    if (pointerType === "touch" && this.armedIndex !== index) {
      this.setHover(index)
      this.armedIndex = index
      return
    }
    const point = this.points[index]
    if (point.source_url) window.open(point.source_url, "_blank", "noopener")
  }

  // Nearest point by screen distance — a plain loop; a race has at most a
  // few dozen polls, which is nothing to scan per pointermove.
  nearestIndex(event) {
    const [px, py] = pointer(event, this.captureRect.node())
    let best = null
    let bestDistance = Infinity
    this.positions.forEach((position, index) => {
      const distance = Math.hypot(position.px - px, position.py - py)
      if (distance < bestDistance) {
        bestDistance = distance
        best = index
      }
    })
    return bestDistance <= HOVER_RADIUS ? best : null
  }

  setHover(index) {
    if (this.hoverIndex === index) return

    this.unhighlight()
    this.hoverIndex = index
    select(this.dotNodes[index]).attr("r", HOVER_DOT_RADIUS).attr("fill-opacity", 1).raise()
    // The pointer cursor promises a click will do something, so it only
    // appears when the hovered point actually has a source to open.
    this.captureRect.style("cursor", this.points[index].source_url ? "pointer" : null)
    this.showTooltip(index)
  }

  clearHover() {
    this.unhighlight()
    this.hoverIndex = null
    this.armedIndex = null
    if (this.captureRect) this.captureRect.style("cursor", null)
    this.tooltip.hide()
  }

  unhighlight() {
    if (this.hoverIndex === null) return

    select(this.dotNodes[this.hoverIndex]).attr("r", DOT_RADIUS).attr("fill-opacity", 0.8)
  }

  // Anchored on the dot itself (container-relative), not the pointer, so the
  // readout holds still while the reader's hand doesn't. Every string below
  // arrives prebuilt from the payload.
  showTooltip(index) {
    const point = this.points[index]
    const color = partyColor(point.party)
    const rows = [ { key: color, value: point.margin_label, valueColor: color, label: "margin" } ]
    if (point.sample_label) rows.push({ value: point.sample_label, label: "sample" })
    const footer = [
      point.sponsor && `Sponsor: ${point.sponsor}`,
      point.internal && (internalsOn() ? "Partisan-sponsored — adjusted & down-weighted" : "Partisan-sponsored — not in this average"),
      point.source_url && "Click to open source ↗"
    ].filter(Boolean).join(" · ") || undefined

    this.tooltip.show(
      this.plotMargin.left + this.positions[index].px,
      this.plotMargin.top + this.positions[index].py,
      { header: point.pollster, subheader: point.date_label, rows, footer }
    )
  }
}

// scaleTime over a single day (every poll fielded the same date) has a
// zero-width domain, which collapses every x onto one edge — pad a day each
// side so a lone cluster renders centered instead.
function paddedDateExtent(points) {
  const times = points.map((point) => point.date.getTime())
  const [minTime, maxTime] = [Math.min(...times), Math.max(...times)]
  const oneDay = 24 * 60 * 60 * 1000
  if (minTime === maxTime) return [new Date(minTime - oneDay), new Date(maxTime + oneDay)]

  return [new Date(minTime), new Date(maxTime)]
}
