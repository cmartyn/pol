// The floating readout every chart shares. One div per chart, positioned
// inside the chart's own container (which becomes position:relative), shown
// on hover/scrub/keyboard focus and hidden otherwise.
//
// Two rules with reasons:
// - Everything is set via textContent, never innerHTML. Pollster and
//   candidate names arrive from scraped Wikipedia tables — untrusted input
//   does not get to write markup into the page.
// - Styles are inline, not Tailwind classes: this module is the only owner
//   of its DOM, and inline styles keep it working even when the Tailwind
//   build hasn't run (the dev Procfile's css watcher is a separate process).
//
// show() takes container-relative pixel coordinates of the anchor point and
// a content spec:
//   { header, subheader, rows: [{ key, value, valueColor, label }], footer }
// Rows follow "values lead, labels follow": the value is the strong element,
// keyed by a short stroke of the series color, the label muted beside it.
export function createTooltip(container) {
  if (getComputedStyle(container).position === "static") {
    container.style.position = "relative"
  }

  const el = document.createElement("div")
  el.setAttribute("aria-hidden", "true")
  el.setAttribute("data-testid", "chart-tooltip")
  el.style.cssText = [
    "position:absolute", "top:0", "left:0", "visibility:hidden",
    "pointer-events:none", "z-index:20",
    "background:#ffffff", "border:1px solid #e2e8f0", "border-radius:6px",
    "box-shadow:0 4px 12px rgba(15,23,42,0.10)",
    "padding:7px 10px", "font-size:12px", "line-height:1.5",
    "color:#0f172a", "white-space:nowrap"
  ].join(";")
  container.appendChild(el)

  const text = (tag, value, css) => {
    const node = document.createElement(tag)
    node.textContent = value
    if (css) node.style.cssText = css
    return node
  }

  function show(x, y, { header, subheader, rows = [], footer }) {
    el.replaceChildren()
    if (header) el.appendChild(text("div", header, "font-weight:600"))
    if (subheader) el.appendChild(text("div", subheader, "color:#64748b;font-size:11px"))

    for (const row of rows) {
      const line = document.createElement("div")
      line.style.cssText = "display:flex;align-items:center;gap:6px;margin-top:2px"
      if (row.key) {
        line.appendChild(text("span", "", `display:inline-block;width:12px;height:2px;border-radius:1px;background:${row.key}`))
      }
      line.appendChild(text("span", row.value, `font-weight:600;color:${row.valueColor || "#0f172a"}`))
      if (row.label) line.appendChild(text("span", row.label, "color:#64748b"))
      el.appendChild(line)
    }

    if (footer) el.appendChild(text("div", footer, "color:#64748b;font-size:11px;margin-top:4px"))

    // Measure at 0,0 while invisible, then place: to the right of the anchor,
    // vertically centered, flipped left when the right edge would clip.
    const containerWidth = container.getBoundingClientRect().width
    const containerHeight = container.getBoundingClientRect().height
    const tooltipWidth = el.offsetWidth
    const tooltipHeight = el.offsetHeight

    let left = x + 14
    if (left + tooltipWidth > containerWidth - 4) left = x - tooltipWidth - 14
    left = Math.max(4, left)

    let top = y - tooltipHeight / 2
    top = Math.max(4, Math.min(top, containerHeight - tooltipHeight - 4))

    el.style.left = `${Math.round(left)}px`
    el.style.top = `${Math.round(top)}px`
    el.style.visibility = "visible"
  }

  function hide() {
    // Park at the origin as well as hiding: a visibility-hidden element still
    // holds its box, and one left at last-hover coordinates stretches the
    // container's scrollWidth after a desktop→mobile resize — which handed
    // the whole page a horizontal scrollbar during verification.
    el.style.visibility = "hidden"
    el.style.left = "0px"
    el.style.top = "0px"
  }

  function destroy() {
    el.remove()
  }

  return { show, hide, destroy, el }
}
