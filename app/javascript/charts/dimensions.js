// Charts render at the container's real pixel width with fixed font sizes,
// instead of scaling a fixed viewBox — scaling is what made axis text
// illegible (~6px effective) on phones. Controllers call observeWidth once
// on connect and re-render whenever the container's width actually changes;
// the ResizeObserver callback is rAF-throttled so a live drag re-renders at
// most once per frame.
export function observeWidth(element, callback) {
  let width = -1
  let frame = null

  const notify = () => {
    frame = null
    const next = Math.round(element.getBoundingClientRect().width)
    if (next > 0 && next !== width) {
      width = next
      callback(next)
    }
  }

  const observer = new ResizeObserver(() => {
    if (frame === null) frame = requestAnimationFrame(notify)
  })
  observer.observe(element)
  // First render happens now, synchronously — the observer's initial
  // callback arrives async, and a chart shouldn't flash empty for a frame.
  notify()

  return () => {
    observer.disconnect()
    if (frame !== null) cancelAnimationFrame(frame)
  }
}

// Pixel geometry for one render: height tracks width between bounds so a
// phone chart is shorter than a desktop one, and margins are whatever the
// chart's own labels need (callers pass them — a party-lettered y-axis needs
// more left room than a bare percentage).
export function frame(width, { margin, minHeight = 200, maxHeight = 300, heightRatio = 0.38 }) {
  const height = Math.round(Math.min(maxHeight, Math.max(minHeight, width * heightRatio)))
  return {
    width,
    height,
    margin,
    innerWidth: Math.max(width - margin.left - margin.right, 0),
    innerHeight: Math.max(height - margin.top - margin.bottom, 0)
  }
}
