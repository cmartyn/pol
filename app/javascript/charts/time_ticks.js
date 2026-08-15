// Political-time axis ticks. d3-axis's default multi-scale format is what
// printed "12 PM / Wed 12 / Thu 13" on a three-day run history — hours and
// weekday names, no month, no year. This replaces it with a fixed ladder of
// political grains (days → weeks → months → quarters → years; never hours)
// and labels that anchor themselves: the first tick always carries its year,
// later ticks only what changed ("Aug 13", "Apr", "Jan 2027").
//
// Returns [{ date, label }] for a d3 time scale; callers draw their own
// <text> elements (hand-drawn axes keep font/color control away from
// d3-axis defaults).
import { timeDay, timeMonday, timeMonth, timeYear } from "d3-time"
import { timeFormat } from "d3-time-format"

const DAY = 24 * 60 * 60 * 1000

// [interval, step, approx ms between ticks, month-grain?]
const LADDER = [
  [timeDay, 1, DAY, false],
  [timeDay, 2, 2 * DAY, false],
  [timeMonday, 1, 7 * DAY, false],
  [timeMonday, 2, 14 * DAY, false],
  [timeMonth, 1, 30 * DAY, true],
  [timeMonth, 3, 91 * DAY, true],
  [timeYear, 1, 365 * DAY, true]
]

const fmtDay = timeFormat("%b %-d")
const fmtDayYear = timeFormat("%b %-d, %Y")
const fmtMonth = timeFormat("%b")
const fmtMonthYear = timeFormat("%b %Y")

function ticksFor([interval, step], start, end) {
  const ticker = step > 1 ? interval.every(step) : interval
  return ticker.range(ticker.ceil(start), new Date(+end + 1))
}

export function timeTicks(scale, pixelWidth) {
  const [start, end] = scale.domain()
  const span = end - start
  if (!(span > 0)) return []

  // ~95px per tick keeps a first-tick "Aug 12, 2026" clear of its neighbor.
  const target = Math.max(2, Math.min(7, Math.floor(pixelWidth / 95)))

  let rung = LADDER.length - 1
  for (let i = 0; i < LADDER.length; i++) {
    if (span / LADDER[i][2] <= target) {
      rung = i
      break
    }
  }

  // A rung can land on a domain that simply contains none of its instants —
  // a Tuesday-to-Saturday domain holds no Monday, a four-day one no month
  // boundary — and "no x-axis at all" is worse than a slightly crowded one.
  // Walk toward finer rungs until at least two ticks exist; each step down
  // is bounded (a rung only reached when the coarser one under-produced), so
  // this can't explode past a handful of labels.
  let dates = ticksFor(LADDER[rung], start, end)
  while (dates.length < 2 && rung > 0) {
    rung -= 1
    dates = ticksFor(LADDER[rung], start, end)
  }

  // The walk (and every()'s anchoring) can overshoot the budget — four
  // quarter ticks squeezed into a phone-width axis leave a 1px gap between
  // "Oct 2025" and "Jan 2026". Thin to a stride, always keeping the first
  // tick: it carries the year anchor.
  if (dates.length > target + 1) {
    const stride = Math.ceil(dates.length / (target + 1))
    dates = dates.filter((_, i) => i % stride === 0)
  }

  // Sub-day domain: even single days can't produce two ticks, so label the
  // endpoints themselves (or the midpoint when both fall on the same date).
  if (dates.length < 2) {
    if (fmtDayYear(start) === fmtDayYear(end)) {
      return [ { date: new Date((+start + +end) / 2), label: fmtDayYear(start) } ]
    }
    return [
      { date: start, label: fmtDayYear(start) },
      { date: end, label: fmtDay(end) }
    ]
  }

  const monthGrain = LADDER[rung][3]
  return dates.map((date, i) => {
    let label
    if (monthGrain) {
      const yearTurned = i > 0 && date.getFullYear() !== dates[i - 1].getFullYear()
      label = i === 0 || yearTurned ? fmtMonthYear(date) : fmtMonth(date)
    } else {
      label = i === 0 ? fmtDayYear(date) : fmtDay(date)
    }
    return { date, label }
  })
}
