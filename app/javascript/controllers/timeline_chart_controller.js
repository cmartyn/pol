import { Controller } from "@hotwired/stimulus"
import { select, pointer } from "d3-selection"
import { scaleLinear, scaleTime } from "d3-scale"
import { line as d3line } from "d3-shape"
import { bisector } from "d3-array"
import { partyColor, CHROME } from "charts/theme"
import { observeWidth, frame } from "charts/dimensions"
import { timeTicks } from "charts/time_ticks"
import { createTooltip } from "charts/tooltip"
import { clusters } from "charts/clusters"

// The race page's win-probability-over-time chart. Reads its data from a
// sibling <script type="application/json"> tag built server-side by
// Site::Charts::Timeline (app/lib/site/charts/timeline.rb) — succeeded model
// runs, oldest first, every run of the last week and a thinned history
// before it. A race added late may have one run (a dot, no line); most have
// a run every two hours since August (a line, with a dot only on the newest
// run).
//
// It opens on the last RECENT_DAYS, where the news is, with "Full season" a
// tap away (the range buttons the ERB leaves hidden until this shows them).
// Keyboard: arrows step one run, Page Up/Down one day, Shift+arrow one week,
// Home/End the ends; each step is read out through a polite live region,
// because the visual tooltip is aria-hidden.
//
// The payload carries the words, this controller carries the geometry: every
// human-readable string (the tooltip dateline, the percent labels) arrives
// pre-formatted from Ruby, and the only vocabulary owned here is the fixed
// series display names and chart labels below. Axes are hand-drawn rather than d3-axis —
// d3-axis's default multi-scale time format is what printed "12 PM / Wed 12"
// on a three-day run history, and charts/time_ticks.js exists to replace it.
//
// The svg renders at the container's real pixel width with fixed font sizes
// (charts/dimensions.js) instead of scaling a fixed viewBox; the ERB's
// viewBox only reserves layout space before this controller connects.

// Series order and display names are fixed; "Other" is only drawn when the
// payload says some run gave a third party a visible probability.
const SERIES = [
  { party: "dem", key: "p_dem_win", name: "Dem" },
  { party: "rep", key: "p_rep_win", name: "Rep" },
  { party: "other", key: "p_other_win", name: "Other" }
]

const bisectDate = bisector((point) => point.date)

// Keeps the first and last runs off the plot's own edge. The domain runs from
// the oldest run to the newest, so without this those two land at exactly 0
// and innerWidth — which is where the capture rect stops, leaving the newest
// run (the point a reader is most likely to reach for) only half a hover
// target and, at a fractional layout position, none at all. Measured on a
// 28-run board: four dots sat exactly on the boundary. Sized to the hovered
// dot's radius (5) so the largest a dot ever draws still sits clear. The same
// constant and the fuller reasoning are in
// polls_scatter_chart_controller.js, where a system test caught it.
const EDGE_INSET = 7

// Runs closer together than this draw no dot of their own: a 3px dot with
// its 1.5px ring is 9px across, and below that the rings overlap and erase
// the line under them.
const MIN_DOT_SPACING = 10

// Corrections closer together than this share one label, as on the chamber
// chart (chamber_timeline_chart_controller.js).
const CLUSTER_PX = 48
const CORRECTION_WORDS = { one: "Correction", many: "Corrections" }

// The default range, and how much longer the history has to run before a
// "Full season" switch would show anything the default doesn't.
const RECENT_DAYS = 30
const RANGE_SLACK_DAYS = 3
const DAY = 24 * 60 * 60 * 1000

// Which view the internals toggle is showing — see
// internals_toggle_controller and polls_scatter_chart_controller.
const internalsOn = () => document.documentElement.dataset.internals === "on"

export default class extends Controller {
  static targets = ["svg", "payload", "plot", "range", "summary", "status"]

  connect() {
    const data = JSON.parse(this.payloadTarget.textContent)
    const parse = (points) => points.map((point) => ({ ...point, date: new Date(point.t) }))
    // Two aligned series, one per internals view; the toggle swaps which one
    // this.points names and re-renders. An incl point is null where it
    // matches the published one, and incl_points is absent from payloads
    // cached before the toggle shipped — the published point stands in.
    const incl = (data.incl_points || data.points).map((point, i) => point || data.points[i])
    this.pointSets = { excl: parse(data.points), incl: parse(incl) }
    this.points = this.pointSets[internalsOn() ? "incl" : "excl"]
    if (this.points.length === 0) return

    // The summary sentence stays for screen readers; the chart replaces it
    // for everyone else.
    if (this.hasSummaryTarget) this.summaryTarget.className = "sr-only"

    // Absent from payloads cached before the chart drew corrections.
    this.corrections = (data.correction_times || []).map((t) => new Date(t))
    this.series = data.show_other ? SERIES : SERIES.slice(0, 2)
    this.band = { low: data.tossup_low_pct, high: data.tossup_high_pct }
    this.activeIndex = null

    const span = this.points[this.points.length - 1].date - this.points[0].date
    const ranged = span > (RECENT_DAYS + RANGE_SLACK_DAYS) * DAY
    this.range = ranged ? "recent" : "all"
    if (this.hasRangeTarget) this.rangeTarget.hidden = !ranged
    this.visible = this.inRange(this.points)

    this.tooltip = createTooltip(this.plotTarget)

    // Keyboard path (the ERB gives the plot tabindex="0"): focus shows the
    // latest run unless a pointer already picked one — pointerdown fires
    // before the focus it causes, and jumping the readout to the end on
    // every click would fight the pointer.
    this.onFocus = () => { if (this.activeIndex === null) this.setActive(this.visible.length - 1, { announce: true }) }
    this.onBlur = () => this.clearActive()
    this.onKeydown = (event) => this.keydown(event)
    this.plotTarget.addEventListener("focus", this.onFocus)
    this.plotTarget.addEventListener("blur", this.onBlur)
    this.plotTarget.addEventListener("keydown", this.onKeydown)

    this.onInternals = () => {
      this.points = this.pointSets[internalsOn() ? "incl" : "excl"]
      this.visible = this.inRange(this.points)
      this.clearActive()
      if (this.lastWidth) this.render(this.lastWidth)
    }
    window.addEventListener("internals:changed", this.onInternals)
    this.teardown = observeWidth(this.plotTarget, (width) => this.render(width))
  }

  disconnect() {
    window.removeEventListener("internals:changed", this.onInternals)
    this.teardown?.()
    this.tooltip?.destroy()
    this.plotTarget.removeEventListener("focus", this.onFocus)
    this.plotTarget.removeEventListener("blur", this.onBlur)
    this.plotTarget.removeEventListener("keydown", this.onKeydown)
  }

  // The range buttons: "recent" or "all".
  setRange(event) {
    this.range = event.currentTarget.dataset.range
    for (const button of this.rangeTarget.querySelectorAll("button")) {
      button.setAttribute("aria-pressed", String(button.dataset.range === this.range))
    }
    this.visible = this.inRange(this.points)
    this.clearActive()
    if (this.lastWidth) this.render(this.lastWidth)
  }

  inRange(points) {
    if (this.range !== "recent") return points

    const cutoff = points[points.length - 1].date.getTime() - RECENT_DAYS * DAY
    return points.filter((point) => point.date.getTime() >= cutoff)
  }

  render(width) {
    this.lastWidth = width
    // right: 76 is end-label room ("Dem 100%" at 12px semibold, which 68
    // clipped);
    // left: 44 fits "100%" at 11px with an 8px gutter; top grows to hold
    // the correction labels when there are any.
    const { height, margin, innerWidth, innerHeight } = frame(width, {
      margin: { top: this.corrections.length ? 26 : 14, right: 76, bottom: 30, left: 44 },
      minHeight: 200,
      maxHeight: 280,
      heightRatio: 0.38
    })
    this.margin = margin
    this.x = scaleTime().domain(paddedDateExtent(this.visible)).range([EDGE_INSET, innerWidth - EDGE_INSET])
    this.y = scaleLinear().domain([0, 100]).range([innerHeight, 0])

    const svg = select(this.svgTarget)
      .attr("viewBox", null)
      .attr("width", width)
      .attr("height", height)
    svg.selectAll("*").remove()

    const g = svg.append("g").attr("transform", `translate(${margin.left},${margin.top})`)

    this.drawBand(g, innerWidth)
    this.drawFrame(g, innerWidth, innerHeight)
    this.drawCorrections(g, innerWidth, innerHeight)

    // Crosshair sits under the data marks but over the chrome; hidden until
    // a pointer or the keyboard picks a run.
    this.crosshair = g.append("line")
      .attr("y1", 0)
      .attr("y2", innerHeight)
      .attr("stroke", CHROME.crosshair)
      .attr("display", "none")

    this.drawSeries(g, innerWidth)
    this.drawEndLabels(g, innerWidth, innerHeight)
    this.drawCapture(g, innerWidth, innerHeight)

    // A resize mid-scrub (rotation, split-screen) keeps the reader's place;
    // otherwise park the hidden tooltip at the origin — hidden means
    // visibility:hidden, so a tooltip left where a wider layout last put it
    // would still stretch scrollWidth and hand the page a horizontal
    // scrollbar after shrinking.
    if (this.activeIndex !== null) {
      this.setActive(this.activeIndex)
    } else {
      this.tooltip.el.style.left = "0px"
      this.tooltip.el.style.top = "0px"
    }
  }

  drawBand(g, innerWidth) {
    const top = this.y(this.band.high)
    const height = Math.max(this.y(this.band.low) - top, 0)

    g.append("rect")
      .attr("x", 0)
      .attr("width", innerWidth)
      .attr("y", top)
      .attr("height", height)
      .attr("fill", CHROME.band)

    // The band names itself so the chart reads without the legend — but only
    // when it is tall enough to hold 10px text without the text spilling out.
    if (height >= 16) {
      g.append("text")
        .attr("x", 6)
        .attr("y", top + 12)
        .attr("fill", CHROME.bandText)
        .attr("font-size", 10)
        .text("Tossup band")
    }
  }

  drawFrame(g, innerWidth, innerHeight) {
    const yTicks = [0, 25, 50, 75, 100]

    g.selectAll(null)
      .data(yTicks)
      .join("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", (value) => this.y(value))
      .attr("y2", (value) => this.y(value))
      .attr("stroke", CHROME.grid)

    g.selectAll(null)
      .data(yTicks)
      .join("text")
      .attr("x", -8)
      .attr("y", (value) => this.y(value))
      .attr("text-anchor", "end")
      .attr("dominant-baseline", "central")
      .attr("fill", CHROME.axisText)
      .attr("font-size", CHROME.fontSize)
      .style("font-variant-numeric", "tabular-nums")
      .text((value) => `${value}%`)

    g.append("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", innerHeight)
      .attr("y2", innerHeight)
      .attr("stroke", CHROME.baseline)

    // Day/week/month ticks from charts/time_ticks.js — never hours, and the
    // first tick anchors its year.
    const tick = g.selectAll(null)
      .data(timeTicks(this.x, innerWidth))
      .join("g")
      .attr("transform", (t) => `translate(${this.x(t.date)},${innerHeight})`)

    tick.append("line")
      .attr("y2", 4)
      .attr("stroke", CHROME.baseline)

    tick.append("text")
      .attr("y", 17)
      .attr("text-anchor", "middle")
      .attr("fill", CHROME.axisText)
      .attr("font-size", CHROME.fontSize)
      .text((t) => t.label)
  }

  // Dashed rules where the inputs were corrected, labeled along the top, as
  // on the chamber chart: a jump at one of these is the data repair the note
  // above the chart describes, not voters moving.
  drawCorrections(g, innerWidth, innerHeight) {
    const [start, end] = this.x.domain()
    const xs = this.corrections.filter((date) => date >= start && date <= end).map((date) => this.x(date))

    g.selectAll(null)
      .data(xs)
      .join("line")
      .attr("x1", (x) => x)
      .attr("x2", (x) => x)
      .attr("y1", -6)
      .attr("y2", innerHeight)
      .attr("stroke", CHROME.crosshair)
      .attr("stroke-dasharray", "3 3")
      .attr("data-testid", "timeline-correction")

    let floor = 0
    for (const cluster of clusters(xs, CLUSTER_PX)) {
      const label = g.append("text")
        .attr("y", -12)
        .attr("fill", CHROME.axisText)
        .attr("font-size", 10)
        .text(cluster.length > 1 ? CORRECTION_WORDS.many : CORRECTION_WORDS.one)
      const labelWidth = label.node().getComputedTextLength()
      const center = (cluster[0] + cluster[cluster.length - 1]) / 2
      const left = Math.max(floor, Math.min(center - labelWidth / 2, innerWidth + this.margin.right - labelWidth - 2))
      label.attr("x", left)
      floor = left + labelWidth + 8
    }
  }

  drawSeries(g, innerWidth) {
    const last = this.visible.length - 1

    // Straight segments between runs, as on the chamber chart: the forecast
    // changes only when a run lands, so a curve would invent the shape between.
    if (last > 0) {
      for (const series of this.series) {
        g.append("path")
          .datum(this.visible)
          .attr("fill", "none")
          .attr("stroke", partyColor(series.party))
          .attr("stroke-width", 2)
          .attr("stroke-linejoin", "round")
          .attr("d", d3line().x((point) => this.x(point.date)).y((point) => this.y(point[series.key] * 100)))
      }
    }

    // A dot per run while the runs sit apart. Packed closer (a run every
    // two hours since August), only the newest run keeps a dot, beside its
    // end label. All dots after all lines, so no series' line crosses
    // another's marks.
    const spread = last === 0 || innerWidth / last >= MIN_DOT_SPACING
    const dotted = spread ? this.visible : [this.visible[last]]
    for (const series of this.series) {
      g.selectAll(null)
        .data(dotted)
        .join("circle")
        .attr("cx", (point) => this.x(point.date))
        .attr("cy", (point) => this.y(point[series.key] * 100))
        .attr("r", 3)
        .attr("fill", partyColor(series.party))
        .attr("stroke", CHROME.ring)
        .attr("stroke-width", 1.5)
    }

    // The run a pointer or the keyboard picks: one marker per series, over
    // the lines and dots.
    this.markers = this.series.map((series) =>
      g.append("circle")
        .attr("r", 4)
        .attr("fill", partyColor(series.party))
        .attr("stroke", CHROME.ring)
        .attr("stroke-width", 1.5)
        .attr("display", "none")
    )
  }

  drawEndLabels(g, innerWidth, innerHeight) {
    const last = this.visible[this.visible.length - 1]
    const labels = this.series.map((series) => ({
      text: `${series.name} ${last.pct_labels[series.party]}`,
      color: partyColor(series.party),
      y: this.y(last[series.key] * 100)
    }))

    // Collision pass: top-to-bottom enforcing 15px of separation (a 12px
    // label plus breathing room), then bottom-to-top to pull any overflow
    // back inside the plot. Three labels at most, so this always resolves.
    labels.sort((a, b) => a.y - b.y)
    let floor = -Infinity
    for (const label of labels) {
      label.y = Math.max(label.y, floor)
      floor = label.y + 15
    }
    let ceiling = innerHeight
    for (let i = labels.length - 1; i >= 0; i--) {
      labels[i].y = Math.max(0, Math.min(labels[i].y, ceiling))
      ceiling = labels[i].y - 15
    }

    g.selectAll(null)
      .data(labels)
      .join("text")
      .attr("x", innerWidth + 8)
      .attr("y", (label) => label.y)
      .attr("fill", (label) => label.color)
      .attr("font-size", 12)
      .attr("font-weight", 600)
      .attr("dominant-baseline", "central")
      .text((label) => label.text)
  }

  drawCapture(g, innerWidth, innerHeight) {
    // One transparent rect owns every pointer event — snapping to the
    // nearest run beats asking readers to hit a 3px dot, especially on touch.
    g.append("rect")
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "none")
      .style("pointer-events", "all")
      .on("pointermove pointerdown", (event) => {
        this.setActive(this.nearestIndex(pointer(event)[0]))
      })
      .on("pointerleave", () => this.clearActive())
  }

  nearestIndex(px) {
    if (this.visible.length === 1) return 0
    return bisectDate.center(this.visible, this.x.invert(px))
  }

  setActive(index, { announce = false } = {}) {
    const point = this.visible[index]
    if (!point) return
    this.activeIndex = index

    const px = this.x(point.date)
    this.crosshair.attr("x1", px).attr("x2", px).attr("display", null)
    this.series.forEach((series, i) => {
      this.markers[i].attr("cx", px).attr("cy", this.y(point[series.key] * 100)).attr("display", null)
    })

    // One readout for every series at once, leaders first; the tooltip
    // anchors on the leading line so it hugs the data it describes.
    const standings = this.series
      .map((series) => ({ ...series, p: point[series.key] }))
      .sort((a, b) => b.p - a.p)

    this.tooltip.show(px + this.margin.left, this.y(standings[0].p * 100) + this.margin.top, {
      header: point.time_label,
      rows: standings.map((series) => ({
        key: partyColor(series.party),
        value: point.pct_labels[series.party],
        valueColor: partyColor(series.party),
        label: series.name
      }))
    })

    // Pointer moves would flood a screen reader; the keyboard path speaks.
    if (announce && this.hasStatusTarget) {
      const readout = standings.map((series) => `${series.name} ${point.pct_labels[series.party]}`).join(", ")
      this.statusTarget.textContent = `${point.time_label}: ${readout}`
    }
  }

  clearActive() {
    this.activeIndex = null
    this.tooltip?.hide()
    this.crosshair?.attr("display", "none")
    for (const marker of this.markers ?? []) marker.attr("display", "none")
  }

  keydown(event) {
    const last = this.visible.length - 1
    const current = this.activeIndex ?? last
    const go = (index) => {
      event.preventDefault()
      this.setActive(Math.max(0, Math.min(index, last)), { announce: true })
    }

    switch (event.key) {
      case "ArrowLeft":
        go(event.shiftKey ? this.stepBy(current, -7 * DAY) : current - 1)
        break
      case "ArrowRight":
        go(event.shiftKey ? this.stepBy(current, 7 * DAY) : current + 1)
        break
      case "PageUp":
        go(this.stepBy(current, -DAY))
        break
      case "PageDown":
        go(this.stepBy(current, DAY))
        break
      case "Home":
        go(0)
        break
      case "End":
        go(last)
        break
      case "Escape":
        this.clearActive()
        break
    }
  }

  // The run nearest a day or a week from the current one, never the
  // current run itself: runs are uneven (two-hourly, more on poll days,
  // thinned before the last week), so a fixed index step would be wrong.
  stepBy(current, ms) {
    const target = new Date(this.visible[current].date.getTime() + ms)
    if (ms < 0) return Math.min(bisectDate.right(this.visible, target) - 1, current - 1)
    return Math.max(bisectDate.left(this.visible, target), current + 1)
  }
}

// scaleTime over a single point (or several points on the same day) has a
// zero-width domain, which draws nothing useful — pad it by a day on each
// side so a lone point renders centered rather than collapsing to an edge.
function paddedDateExtent(points) {
  const times = points.map((point) => point.date.getTime())
  const [minTime, maxTime] = [Math.min(...times), Math.max(...times)]
  const oneDay = 24 * 60 * 60 * 1000
  if (minTime === maxTime) return [new Date(minTime - oneDay), new Date(maxTime + oneDay)]

  return [new Date(minTime), new Date(maxTime)]
}
