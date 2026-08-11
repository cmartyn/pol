import { Controller } from "@hotwired/stimulus"
import { select } from "d3-selection"
import { scaleLinear, scaleTime } from "d3-scale"
import { axisBottom, axisLeft } from "d3-axis"

// A race page's polls-over-time scatter: every poll at (field date, margin),
// plus the current weighted average as a horizontal reference line. Data
// comes from Site::Charts::PollsScatter (app/lib/site/charts/polls_scatter.rb)
// via a sibling <script type="application/json"> tag. The controller's root
// element isn't rendered at all when the race has no polls — see
// races/_polls_scatter_chart.html.erb — so this never has to draw an empty
// axes box.
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
    const margin = { top: 16, right: 16, bottom: 28, left: 44 }
    const innerWidth = width - margin.left - margin.right
    const innerHeight = height - margin.top - margin.bottom

    const points = data.points.map((point) => ({ ...point, date: new Date(point.t) }))
    const magnitudes = points.map((point) => Math.abs(point.margin))
    if (data.average_margin !== null) magnitudes.push(Math.abs(data.average_margin))
    const bound = Math.max(4, ...magnitudes) * 1.15

    const x = scaleTime().domain(paddedDateExtent(points)).range([0, innerWidth])
    const y = scaleLinear().domain([-bound, bound]).range([innerHeight, 0])

    const g = svg
      .attr("viewBox", `0 0 ${width} ${height}`)
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`)

    g.append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .attr("font-size", "10px")
      .call(axisBottom(x).ticks(6).tickSizeOuter(0))

    g.append("g")
      .attr("font-size", "10px")
      .call(axisLeft(y).ticks(5).tickFormat((value) => (value > 0 ? `+${value}` : `${value}`)))

    g.append("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", y(0))
      .attr("y2", y(0))
      .attr("stroke", "#cbd5e1")

    if (data.average_margin !== null) {
      g.append("line")
        .attr("x1", 0)
        .attr("x2", innerWidth)
        .attr("y1", y(data.average_margin))
        .attr("y2", y(data.average_margin))
        .attr("stroke", "#d97706")
        .attr("stroke-width", 1.5)
        .attr("stroke-dasharray", "4,3")
    }

    g.selectAll(null)
      .data(points)
      .join("circle")
      .attr("cx", (point) => x(point.date))
      .attr("cy", (point) => y(point.margin))
      .attr("r", 4)
      .attr("fill", (point) => (point.margin >= 0 ? "#1d4ed8" : "#b91c1c"))
      .attr("fill-opacity", 0.75)
      .append("title")
      .text((point) => `${point.pollster}: ${point.margin > 0 ? "+" : ""}${point.margin}`)
  }
}

// See timeline_chart_controller.js for why a degenerate (single-day) domain
// needs padding.
function paddedDateExtent(points) {
  const times = points.map((point) => point.date.getTime())
  const [minTime, maxTime] = [Math.min(...times), Math.max(...times)]
  const oneDay = 24 * 60 * 60 * 1000
  if (minTime === maxTime) return [new Date(minTime - oneDay), new Date(maxTime + oneDay)]

  return [new Date(minTime), new Date(maxTime)]
}
