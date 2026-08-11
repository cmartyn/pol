import { Controller } from "@hotwired/stimulus"
import { select } from "d3-selection"
import { scaleLinear, scaleTime } from "d3-scale"
import { axisBottom, axisLeft } from "d3-axis"
import { line as d3line, curveMonotoneX } from "d3-shape"

// The race page's win-probability-over-time chart. Reads its data from a
// sibling <script type="application/json"> tag built server-side by
// Site::Charts::Timeline (app/lib/site/charts/timeline.rb) — one point per
// succeeded model run, oldest first. History is short right now, so this
// has to look right with one point (a dot, no line) just as well as with
// several (a small multi-line chart, one line per party whose probability
// is ever visible).
//
// The <svg> keeps a fixed internal coordinate system (viewBox) and fills
// its container's width via CSS, so it's responsive without recomputing
// anything on resize.
export default class extends Controller {
  static targets = ["svg", "payload"]

  connect() {
    this.render()
  }

  render() {
    const data = JSON.parse(this.payloadTarget.textContent)
    const svg = select(this.svgTarget)
    svg.selectAll("*").remove()
    if (data.points.length === 0) return

    const width = 640
    const height = 220
    const margin = { top: 16, right: 16, bottom: 28, left: 40 }
    const innerWidth = width - margin.left - margin.right
    const innerHeight = height - margin.top - margin.bottom

    const points = data.points.map((point) => ({ ...point, date: new Date(point.t) }))
    const x = scaleTime().domain(paddedDateExtent(points)).range([0, innerWidth])
    const y = scaleLinear().domain([0, 100]).range([innerHeight, 0])

    const g = svg
      .attr("viewBox", `0 0 ${width} ${height}`)
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`)

    // The tossup band, so a line wandering through the middle reads as
    // "too close to call" at a glance rather than requiring the legend.
    g.append("rect")
      .attr("x", 0)
      .attr("width", innerWidth)
      .attr("y", y(data.tossup_high_pct))
      .attr("height", Math.max(y(data.tossup_low_pct) - y(data.tossup_high_pct), 0))
      .attr("fill", "#f1f5f9")

    g.append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .attr("font-size", "10px")
      .call(axisBottom(x).ticks(Math.min(points.length, 6)).tickSizeOuter(0))

    g.append("g")
      .attr("font-size", "10px")
      .call(axisLeft(y).ticks(5).tickFormat((value) => `${value}%`))

    const series = [
      { key: "p_dem_win", color: "#1d4ed8", label: "Dem" },
      { key: "p_rep_win", color: "#b91c1c", label: "Rep" }
    ]
    if (data.show_other) series.push({ key: "p_other_win", color: "#64748b", label: "Other" })

    series.forEach(({ key, color, label }) => {
      if (points.length > 1) {
        const lineGenerator = d3line()
          .x((point) => x(point.date))
          .y((point) => y(point[key] * 100))
          .curve(curveMonotoneX)

        g.append("path")
          .datum(points)
          .attr("fill", "none")
          .attr("stroke", color)
          .attr("stroke-width", 2)
          .attr("d", lineGenerator)
      }

      g.selectAll(null)
        .data(points)
        .join("circle")
        .attr("cx", (point) => x(point.date))
        .attr("cy", (point) => y(point[key] * 100))
        .attr("r", 3.5)
        .attr("fill", color)
        .append("title")
        .text((point) => `${label} ${point.label}: ${Math.round(point[key] * 100)}%`)
    })
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
