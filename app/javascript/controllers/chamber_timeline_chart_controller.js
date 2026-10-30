import { Controller } from "@hotwired/stimulus"
import { select, pointer } from "d3-selection"
import { scaleLinear, scaleTime } from "d3-scale"
import { line as d3line, area as d3area, curveStepAfter } from "d3-shape"
import { bisector } from "d3-array"
import { partyColor, CHROME } from "charts/theme"
import { observeWidth } from "charts/dimensions"
import { timeTicks } from "charts/time_ticks"
import { createTooltip } from "charts/tooltip"
import { clusters } from "charts/clusters"

// A chamber page's "Forecast over time": two panels on one time axis. The
// top one is each party's chance of control in every model run; the bottom
// one is expected Democratic-caucus seats, shaded with the 5th–95th
// percentile range of that run's simulations. Data comes from a sibling
// <script type="application/json"> built by Site::Charts::ChamberTimeline
// (app/lib/site/charts/chamber_timeline.rb), columnar and aligned with `t`.
//
// The conventions are timeline_chart_controller.js's: the payload carries
// every word and percentage, this file only places them; axes are drawn by
// hand with charts/time_ticks.js; the chart renders at its real pixel width.
//
// What is different here, and why:
// - Every run is drawn, straight segments, no dots. 1,200+ runs is a line,
//   and a curve or a rolling average would be a story about the forecast
//   rather than the forecast.
// - The time axis ends at election day, so the days still to come show as
//   room at the right. The current values are labelled where the lines end.
// - A dashed rule crosses both panels wherever a run's inputs changed (see
//   Site::ChamberHistory#corrections), so a jump at a correction reads as a
//   correction, not as voters moving.

const SERIES = [
  { party: "dem", key: "dem", labels: "dem_labels", name: "Dem" },
  { party: "rep", key: "rep", labels: "rep_labels", name: "Rep" }
]

const bisectDate = bisector((date) => date)

// Keeps the first and last runs clear of the capture rect's edges; see
// timeline_chart_controller.js for the measurement behind it.
const EDGE_INSET = 7

// top: the panel title and correction labels; right: end labels ("Dem 69%"
// at 12px semibold); left: "100%" at 11px plus a gutter; bottom: date ticks.
const MARGIN = { top: 26, right: 60, bottom: 30, left: 40 }
// Room between the panels for the seats panel's own title.
const PANEL_GAP = 38
// Corrections closer together than this share one label.
const CLUSTER_PX = 48

const SEATS_BAND_OPACITY = 0.14
const HALO = { stroke: "#ffffff", width: 3 }

const internalsOn = () => document.documentElement.dataset.internals === "on"

export default class extends Controller {
  static targets = ["svg", "payload", "live"]

  connect() {
    this.payload = JSON.parse(this.payloadTarget.textContent)
    this.dates = this.payload.t.map((ms) => new Date(ms))
    if (this.dates.length === 0) return

    this.words = this.payload.words
    this.correctionIndexes = new Set(this.payload.corrections.map((correction) => correction.index))
    this.series = this.payload.series[internalsOn() ? "incl" : "excl"]
    this.activeIndex = null
    this.tooltip = createTooltip(this.element)

    // Focus shows the latest run unless a pointer already picked one —
    // pointerdown fires before the focus it causes.
    this.onFocus = () => { if (this.activeIndex === null) this.setActive(this.dates.length - 1, { announce: true }) }
    this.onBlur = () => this.clearActive()
    this.onKeydown = (event) => this.keydown(event)
    this.element.addEventListener("focus", this.onFocus)
    this.element.addEventListener("blur", this.onBlur)
    this.element.addEventListener("keydown", this.onKeydown)

    this.onInternals = () => {
      this.series = this.payload.series[internalsOn() ? "incl" : "excl"]
      this.clearActive()
      if (this.lastWidth) this.render(this.lastWidth)
    }
    window.addEventListener("internals:changed", this.onInternals)
    this.teardown = observeWidth(this.element, (width) => this.render(width))
  }

  disconnect() {
    window.removeEventListener("internals:changed", this.onInternals)
    this.teardown?.()
    this.tooltip?.destroy()
    this.element.removeEventListener("focus", this.onFocus)
    this.element.removeEventListener("blur", this.onBlur)
    this.element.removeEventListener("keydown", this.onKeydown)
  }

  render(width) {
    this.lastWidth = width
    const innerWidth = Math.max(width - MARGIN.left - MARGIN.right, 0)
    const controlHeight = clamp(Math.round(width * 0.26), 140, 200)
    const seatsHeight = clamp(Math.round(width * 0.18), 100, 140)
    const height = MARGIN.top + controlHeight + PANEL_GAP + seatsHeight + MARGIN.bottom
    this.layout = { innerWidth, controlHeight, seatsHeight, seatsTop: controlHeight + PANEL_GAP }
    this.layout.plotBottom = this.layout.seatsTop + seatsHeight

    const election = new Date(this.payload.election.t)
    this.electionDate = election
    this.x = scaleTime().domain(dateDomain(this.dates, election)).range([EDGE_INSET, innerWidth - EDGE_INSET])
    this.yControl = scaleLinear().domain([0, 100]).range([controlHeight, 0])
    this.ySeats = scaleLinear().domain(this.seatsDomain()).nice(4).range([seatsHeight, 0])

    const svg = select(this.svgTarget)
      .attr("viewBox", null)
      .attr("width", width)
      .attr("height", height)
    svg.selectAll("*").remove()

    const root = svg.append("g").attr("transform", `translate(${MARGIN.left},${MARGIN.top})`)
    const control = root.append("g")
    const seats = root.append("g").attr("transform", `translate(0,${this.layout.seatsTop})`)

    const titleWidth = this.drawTitle(control, this.words.control_panel)
    this.drawTitle(seats, this.words.seats_panel)
    this.drawControlFrame(control)
    this.drawSeatsFrame(seats)
    this.drawTimeAxis(root)
    this.drawRules(root, titleWidth)

    this.crosshair = root.append("line")
      .attr("y1", 0)
      .attr("y2", this.layout.plotBottom)
      .attr("stroke", CHROME.crosshair)
      .attr("display", "none")

    this.drawSeatsData(seats)
    this.drawControlData(control)
    this.drawCapture(root)

    // A resize mid-scrub keeps the reader's place; otherwise park the hidden
    // tooltip at the origin so it cannot stretch the page after a shrink.
    if (this.activeIndex !== null) {
      this.setActive(this.activeIndex)
    } else {
      this.tooltip.el.style.left = "0px"
      this.tooltip.el.style.top = "0px"
    }
  }

  // Both internals views and the majority line, so toggling the view never
  // rescales the axis under the reader.
  seatsDomain() {
    const values = [this.payload.majority.seats]
    for (const series of Object.values(this.payload.series)) {
      for (const key of ["seats", "low", "high"]) {
        for (const value of series[key]) if (value !== null) values.push(value)
      }
    }
    return [Math.min(...values) - 1, Math.max(...values) + 1]
  }

  drawTitle(g, text) {
    const title = g.append("text")
      .attr("x", 0)
      .attr("y", -12)
      .attr("fill", CHROME.threshold)
      .attr("font-size", CHROME.fontSize)
      .attr("font-weight", 600)
      .text(text)
    return title.node().getComputedTextLength()
  }

  drawControlFrame(g) {
    const { innerWidth } = this.layout
    const ticks = [0, 25, 50, 75, 100]

    g.selectAll(null)
      .data(ticks)
      .join("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", (value) => this.yControl(value))
      .attr("y2", (value) => this.yControl(value))
      // 50% is where control changes hands; it gets the baseline's weight.
      .attr("stroke", (value) => (value === 50 || value === 0 ? CHROME.baseline : CHROME.grid))

    yLabels(g, ticks, this.yControl, (value) => `${value}%`)
  }

  drawSeatsFrame(g) {
    const { innerWidth, seatsHeight } = this.layout
    const ticks = this.ySeats.ticks(4).filter(Number.isInteger)

    g.selectAll(null)
      .data(ticks)
      .join("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", (value) => this.ySeats(value))
      .attr("y2", (value) => this.ySeats(value))
      .attr("stroke", CHROME.grid)

    g.append("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", seatsHeight)
      .attr("y2", seatsHeight)
      .attr("stroke", CHROME.baseline)

    yLabels(g, ticks, this.ySeats, (value) => String(value))

    // The line a seat count has to reach for Democratic control, labelled in
    // the seat histogram's words. The label sits above the line unless that
    // would leave the panel.
    //
    // When the latest expected seats sit near that line, the line breaks
    // around their end label: a dash running up to "51.8" reads as "-51.8".
    const majorityY = this.ySeats(this.payload.majority.seats)
    const end = this.seatsEndLabel()
    let segments = [[0, innerWidth]]
    if (Math.abs(end.y - majorityY) < 8) {
      const width = measureText(g, end.text, 12, 600)
      segments = [[0, end.x - 3], [end.x + width + 3, innerWidth]].filter(([x1, x2]) => x2 > x1)
    }
    g.selectAll(null)
      .data(segments)
      .join("line")
      .attr("x1", ([x1]) => x1)
      .attr("x2", ([, x2]) => x2)
      .attr("y1", majorityY)
      .attr("y2", majorityY)
      .attr("stroke", CHROME.threshold)
      .attr("stroke-dasharray", "4 3")
      .attr("data-testid", "chamber-timeline-majority")
    haloText(g.append("text"))
      .attr("x", 4)
      .attr("y", majorityY < 14 ? majorityY + 12 : majorityY - 5)
      .attr("fill", CHROME.threshold)
      .attr("font-size", 10)
      .text(this.payload.majority.label)
  }

  // Date ticks under the seats panel, ending in an "Election Day" tick at
  // the axis's end. Regular ticks that would collide with it are dropped.
  drawTimeAxis(root) {
    const { plotBottom, innerWidth } = this.layout
    const axis = root.append("g").attr("transform", `translate(0,${plotBottom})`)
    const electionX = this.x(this.electionDate)

    axis.append("line").attr("x1", electionX).attr("x2", electionX).attr("y2", 4).attr("stroke", CHROME.baseline)
    const electionLabel = axis.append("text")
      .attr("x", electionX)
      .attr("y", 17)
      .attr("text-anchor", "end")
      .attr("fill", CHROME.axisText)
      .attr("font-size", CHROME.fontSize)
      .attr("font-weight", 600)
      .text(this.payload.election.label)
    const electionLeft = electionX - electionLabel.node().getComputedTextLength()

    // Each tick is measured once drawn: "Oct" fits where "Sep 28" would
    // not, and guessing one width for both dropped the month on a phone.
    for (const t of timeTicks(this.x, innerWidth)) {
      const x = this.x(t.date)
      const tick = axis.append("g").attr("transform", `translate(${x},0)`)
      const label = tick.append("text")
        .attr("y", 17)
        .attr("text-anchor", "middle")
        .attr("fill", CHROME.axisText)
        .attr("font-size", CHROME.fontSize)
        .text(t.label)
      if (x + label.node().getComputedTextLength() / 2 + 8 > electionLeft) {
        tick.remove()
      } else {
        tick.append("line").attr("y2", 4).attr("stroke", CHROME.baseline)
      }
    }
  }

  // Vertical rules across both panels: election day solid, corrections
  // dashed. Correction labels share the top row with the panel title, so
  // they cluster when close and never start before the title ends.
  drawRules(root, titleWidth) {
    const { plotBottom, innerWidth } = this.layout
    const electionX = this.x(this.electionDate)

    root.append("line")
      .attr("x1", electionX)
      .attr("x2", electionX)
      .attr("y1", 0)
      .attr("y2", plotBottom)
      .attr("stroke", CHROME.baseline)

    const xs = this.payload.corrections.map((correction) => this.x(new Date(correction.t)))
    root.selectAll(null)
      .data(xs)
      .join("line")
      .attr("x1", (x) => x)
      .attr("x2", (x) => x)
      .attr("y1", -6)
      .attr("y2", plotBottom)
      .attr("stroke", CHROME.crosshair)
      .attr("stroke-dasharray", "3 3")
      .attr("data-testid", "chamber-timeline-correction")

    let floor = titleWidth + 10
    for (const cluster of clusters(xs, CLUSTER_PX)) {
      const label = root.append("text")
        .attr("y", -12)
        .attr("fill", CHROME.axisText)
        .attr("font-size", 10)
        .text(cluster.length > 1 ? this.words.corrections : this.words.correction)
      const labelWidth = label.node().getComputedTextLength()
      const center = (cluster[0] + cluster[cluster.length - 1]) / 2
      const left = clamp(center - labelWidth / 2, floor, innerWidth + MARGIN.right - labelWidth - 2)
      label.attr("x", left)
      floor = left + labelWidth + 8
    }
  }

  drawSeatsData(g) {
    const points = this.dates.map((date, i) => ({ date, i }))
    const hasRange = (point) => this.series.low[point.i] !== null && this.series.high[point.i] !== null

    // Percentiles are whole seat counts that hold until a run changes them,
    // so the band steps. Joining runs with slanted edges drew notches at
    // every one-seat change that no run actually produced.
    g.append("path")
      .datum(points)
      .attr("fill", partyColor("dem"))
      .attr("fill-opacity", SEATS_BAND_OPACITY)
      .attr("d", d3area()
        .defined(hasRange)
        .curve(curveStepAfter)
        .x((point) => this.x(point.date))
        .y0((point) => this.ySeats(this.series.low[point.i]))
        .y1((point) => this.ySeats(this.series.high[point.i])))

    const seatsAt = (point) => this.ySeats(this.series.seats[point.i])
    this.drawLine(g, points, seatsAt, partyColor("dem"))

    const end = this.seatsEndLabel()
    haloText(g.append("text"))
      .attr("x", end.x)
      .attr("y", end.y)
      .attr("dominant-baseline", "central")
      .attr("fill", partyColor("dem"))
      .attr("font-size", 12)
      .attr("font-weight", 600)
      .attr("data-testid", "chamber-timeline-seats-label")
      .text(end.text)

    this.seatsMarker = marker(g, partyColor("dem"))
  }

  // Where the latest run's expected seats are labelled: just past the end
  // of the line. The majority line needs it too, to break around it.
  seatsEndLabel() {
    const last = this.dates.length - 1
    return {
      x: this.x(this.dates[last]) + 6,
      y: this.ySeats(this.series.seats[last]),
      text: this.series.seats_labels[last]
    }
  }

  drawControlData(g) {
    const points = this.dates.map((date, i) => ({ date, i }))
    for (const series of SERIES) {
      this.drawLine(g, points, (point) => this.yControl(this.series[series.key][point.i] * 100), partyColor(series.party))
    }

    // End labels where the lines end, pushed apart top-to-bottom by 15px
    // and pulled back inside the panel bottom-to-top, as on the race chart.
    const lastIndex = points.length - 1
    const labels = SERIES.map((series) => ({
      text: `${series.name} ${this.series[series.labels][lastIndex]}`,
      color: partyColor(series.party),
      y: this.yControl(this.series[series.key][lastIndex] * 100)
    })).sort((a, b) => a.y - b.y)
    let floor = -Infinity
    for (const label of labels) {
      label.y = Math.max(label.y, floor)
      floor = label.y + 15
    }
    let ceiling = this.layout.controlHeight
    for (let i = labels.length - 1; i >= 0; i--) {
      labels[i].y = Math.max(0, Math.min(labels[i].y, ceiling))
      ceiling = labels[i].y - 15
    }
    const labelX = this.x(this.dates[lastIndex]) + 6
    for (const label of labels) {
      haloText(g.append("text"))
        .attr("x", labelX)
        .attr("y", label.y)
        .attr("dominant-baseline", "central")
        .attr("fill", label.color)
        .attr("font-size", 12)
        .attr("font-weight", 600)
        .text(label.text)
    }

    this.controlMarkers = SERIES.map((series) => marker(g, partyColor(series.party)))
  }

  // Straight segments between runs. A single run has no segment to draw, so
  // it gets a dot instead.
  drawLine(g, points, y, color) {
    if (points.length > 1) {
      g.append("path")
        .datum(points)
        .attr("fill", "none")
        .attr("stroke", color)
        .attr("stroke-width", 2)
        .attr("stroke-linejoin", "round")
        .attr("d", d3line().x((point) => this.x(point.date)).y(y))
    } else {
      g.append("circle")
        .attr("cx", this.x(points[0].date))
        .attr("cy", y(points[0]))
        .attr("r", 3)
        .attr("fill", color)
    }
  }

  drawCapture(root) {
    // One transparent rect over both panels owns every pointer event and
    // snaps to the nearest run.
    root.append("rect")
      .attr("width", this.layout.innerWidth)
      .attr("height", this.layout.plotBottom)
      .attr("fill", "none")
      .style("pointer-events", "all")
      .on("pointermove pointerdown", (event) => this.setActive(this.nearestIndex(pointer(event)[0])))
      .on("pointerleave", () => this.clearActive())
  }

  nearestIndex(px) {
    if (this.dates.length === 1) return 0
    return bisectDate.center(this.dates, this.x.invert(px))
  }

  setActive(index, { announce = false } = {}) {
    if (index < 0 || index >= this.dates.length) return
    this.activeIndex = index

    const px = this.x(this.dates[index])
    const seatsY = this.layout.seatsTop + this.ySeats(this.series.seats[index])
    this.crosshair.attr("x1", px).attr("x2", px).attr("display", null)
    SERIES.forEach((series, i) => {
      this.controlMarkers[i].attr("cx", px).attr("cy", this.yControl(this.series[series.key][index] * 100)).attr("display", null)
    })
    this.seatsMarker.attr("cx", px).attr("cy", seatsY - this.layout.seatsTop).attr("display", null)

    const standings = SERIES
      .map((series) => ({ ...series, p: this.series[series.key][index], label: this.series[series.labels][index] }))
      .sort((a, b) => b.p - a.p)
    const range = this.series.range_labels[index]
    const corrected = this.correctionIndexes.has(index)

    this.tooltip.show(px + MARGIN.left, this.yControl(standings[0].p * 100) + MARGIN.top, {
      header: this.payload.time_labels[index],
      subheader: corrected ? this.words.correction_readout : null,
      rows: [
        ...standings.map((series) => ({
          key: partyColor(series.party),
          value: series.label,
          valueColor: partyColor(series.party),
          label: series.name
        })),
        {
          key: partyColor("dem"),
          value: this.series.seats_labels[index],
          valueColor: partyColor("dem"),
          label: this.words.seats_row
        }
      ],
      footer: range ? `${this.words.range}: ${range}` : null
    })

    // The tooltip is aria-hidden; keyboard steps are announced here instead.
    // Pointer moves are not, or a reader would hear every pixel.
    if (announce && this.hasLiveTarget) {
      const parts = [
        `${this.payload.time_labels[index]}:`,
        SERIES.map((series) => `${series.name} ${this.series[series.labels][index]}`).join(", ") + ",",
        `${this.series.seats_labels[index]} ${this.words.seats_row}`
      ]
      if (range) parts.push(`(${this.words.range} ${range})`)
      if (corrected) parts.push(`— ${this.words.correction_readout}`)
      this.liveTarget.textContent = parts.join(" ")
    }
  }

  clearActive() {
    this.activeIndex = null
    this.tooltip?.hide()
    this.crosshair?.attr("display", "none")
    for (const dot of [...(this.controlMarkers ?? []), this.seatsMarker]) dot?.attr("display", "none")
  }

  keydown(event) {
    const last = this.dates.length - 1
    const current = this.activeIndex ?? last
    const step = {
      ArrowLeft: Math.max(current - 1, 0),
      ArrowRight: Math.min(current + 1, last),
      Home: 0,
      End: last
    }[event.key]

    if (step !== undefined) {
      event.preventDefault()
      this.setActive(step, { announce: true })
    } else if (event.key === "Escape") {
      this.clearActive()
    }
  }
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(value, high))
}

// From the first run to election day — or to the last run, once runs pass
// it. A single run on election day itself would leave no width, so pad.
function dateDomain(dates, election) {
  const start = dates[0]
  const end = new Date(Math.max(election.getTime(), dates[dates.length - 1].getTime()))
  if (end.getTime() === start.getTime()) {
    const day = 24 * 60 * 60 * 1000
    return [new Date(start.getTime() - day), new Date(end.getTime() + day)]
  }
  return [start, end]
}

function yLabels(g, ticks, scale, format) {
  g.selectAll(null)
    .data(ticks)
    .join("text")
    .attr("x", -8)
    .attr("y", (value) => scale(value))
    .attr("text-anchor", "end")
    .attr("dominant-baseline", "central")
    .attr("fill", CHROME.axisText)
    .attr("font-size", CHROME.fontSize)
    .style("font-variant-numeric", "tabular-nums")
    .text(format)
}

// The rendered width of a label before it is placed, from a throwaway node
// with the same type settings.
function measureText(g, text, fontSize, fontWeight) {
  const probe = g.append("text").attr("font-size", fontSize).attr("font-weight", fontWeight).text(text)
  const width = probe.node().getComputedTextLength()
  probe.remove()
  return width
}

// Labels that can sit over a line or rule keep a white outline so they stay
// legible on top of it.
function haloText(text) {
  return text
    .attr("stroke", HALO.stroke)
    .attr("stroke-width", HALO.width)
    .attr("stroke-linejoin", "round")
    .attr("paint-order", "stroke")
}

function marker(g, color) {
  return g.append("circle")
    .attr("r", 4)
    .attr("fill", color)
    .attr("stroke", CHROME.ring)
    .attr("stroke-width", 1.5)
    .attr("display", "none")
}
