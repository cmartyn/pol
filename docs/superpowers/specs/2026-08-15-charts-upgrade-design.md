# Charts upgrade: interactivity + labels

**Date:** 2026-08-15 · **Status:** approved for implementation (autonomous session; user asked for "more interactive, fix the labels, feel free to use subagents")

## Problems (observed live on /races/senate-2026-nc and /)

1. **Timeline x-axis is unreadable.** All 13 model runs span Aug 12–15, so d3's
   default multi-scale tick format prints "12 PM / Wed 12 / Thu 13" — hours and
   weekday names with no month or year anywhere.
2. **Scatter x-axis mixes bare month names with a bare year** ("October … 2026 …
   April"); "October" is actually 2025 and nothing says so.
3. **Scatter y-axis is party-blind.** "+20/+10/0/−10" forces the reader to infer
   that positive means Dem (and on the three no-Dem races it doesn't).
4. **Native `<title>` tooltips only**: slow, unformatted, invisible on touch. On
   mobile the charts have zero interactivity and ~6px effective axis text
   (fixed 640×220 viewBox scaled down).
5. **Histogram axis** has only end-point numbers with a caption sentence sitting
   inside the axis row; the majority threshold line is unlabeled; no hover readout.
6. Reference lines (poll average) and series (timeline lines) are unlabeled
   on-chart; identity lives only in a small legend below.

## Approaches considered

- **A. Fix in JS only** — keep payloads as-is, reformat labels client-side.
  Least churn, but re-implements `Site::Format` conventions in JS: two sources
  of truth for "D+9.8"/"Even"/party letters. Rejected — this repo's whole
  design fights that kind of drift (see `Site::RaceSides`' header comment).
- **B. Server-formatted payloads + hand-rolled interaction layer** ← chosen.
  *The payload carries the words, the JS carries the geometry.* Ruby (already
  unit-tested) formats every string; Stimulus/d3 place text and handle pointer
  events. No new dependencies; works within the vendored d3 modules
  (selection/scale/axis/shape/array/time — no d3-transition/zoom needed).
- **C. Adopt a chart library** (uPlot / Observable Plot). Most capability,
  new vendored dep, restyling fight, against the lean no-Node ethos. Rejected.

## Design

### Shared modules — `app/javascript/charts/` (new importmap `pin_all_from`)

- `dimensions.js` — charts render at **container size** with **fixed font
  sizes** instead of scaling a fixed viewBox. Measures container width, returns
  width/height/margins (height clamped, wider margins where party-letter ticks
  need room). A `ResizeObserver` (rAF-throttled) triggers re-render. This is
  what fixes mobile text.
- `time_ticks.js` — political time axis: picks day/week/month tick interval
  from domain span and pixel width; labels are "Aug 12" at day/week grain,
  "Apr" at month grain with "Oct 2025 / Jan 2026"-style anchoring at the first
  tick and every year boundary. Never hours.
- `tooltip.js` — one absolutely-positioned div per chart (container gets
  `relative`), built **only via `textContent`** (pollster names are scraped =
  untrusted), `pointer-events:none`, flips near the right edge, hidden until
  pointer/focus. Rows follow "values lead, labels follow" with a short colored
  line-key.
- `party_colors.js` — one map: dem `#1d4ed8` (blue-700), rep `#b91c1c`
  (red-700), ind/other `#64748b` (slate-500), average-line amber-600.
  Validated with the dataviz palette checker: worst adjacent CVD ΔE 14.6
  (target ≥ 8), all ≥ 3:1 on white. Slate is deliberately low-chroma — it is
  the "Other" fold, always legend-keyed, never an identity slot.

### Timeline (win probability over time)

- X axis day-grain ticks ("Aug 12"), y axis 0–100% with solid hairline
  gridlines (slate-100); tossup band keeps its fill and gains a tiny in-band
  "Tossup band" label at the left edge (slate-400), so the chart explains
  itself without the legend.
- **Direct end labels** "Dem 93%" / "Rep 7%" (+ "Other") at line ends in party
  colors (site-wide convention: margins and probabilities are always
  party-colored text; both pass AA on white). Collision pass: sort by y,
  enforce minimum separation.
- **Crosshair + single tooltip, every series at once**: transparent capture
  rect over the plot; pointer snaps (d3-array bisector) to the nearest run;
  vertical hairline + enlarged dots with 2px white rings at that run; tooltip
  header is the run's server-formatted dateline ("Aug 14, 2026 · 6:47 AM UTC"),
  rows "93% Dem / 7% Rep" with line-keys. Works for mouse and touch (pointer
  events). **Keyboard:** wrapper is focusable; ←/→ steps through runs showing
  the same readout; Esc/blur clears.
- Payload additions (`Site::Charts::Timeline`): per-point `time_label`
  (tooltip dateline) and `pct_labels` {dem/rep/other} via `Site::Format.percent`.

### Polls scatter (margins over time)

- Y-axis ticks become **party-anchored margins**: "D+20 / D+10 / Even / R+10 /
  R+20", letters from the payload's existing `side_a_party`/`side_b_party`
  through `Site::Format::PARTY_LETTER` (so the three no-Dem races label as
  I+/R+). Lettered ticks wear the party color (semibold 11px); "Even" stays
  slate. Clean 5- or 10-point steps.
- X axis via `time_ticks` ("Oct 2025 … Jan 2026 … Apr … Jul").
- Zero line = solid hairline; average line stays dashed amber (it is a
  threshold/reference, where dashing means something) and gains a right-end
  on-chart label "avg D+10.2" with a white halo.
- Dots colored by **which side leads** (not "positive = blue"): sign picks
  side_a/side_b party, mapped through `party_colors`. r≈4.5 with white ring.
- **Nearest-point hover** (≤ ~28px), hovered dot enlarges; tooltip: pollster
  (strong) + field-period dateline, margin label (party-colored, e.g.
  "D+13.0"), sample "600 · LV", sponsor when present, "open source ↗" hint;
  **click/tap opens `source_url`** (rel=noopener). The poll table below remains
  the no-hover/keyboard path to every value (tooltips enhance, never gate).
- Payload additions (`Site::Charts::PollsScatter`): per-point `margin_label`,
  `party`, `date_label` ("Aug 6–9, 2026", collapsing within-month), `sample_label`
  ("600 LV" / nil), `sponsor`; top-level `side_a_letter`, `side_b_letter`,
  `average_label`, `average_party`.

### Seat histogram (dashboard + /house)

- Stays **server-rendered SVG** (the partial's rationale still holds) with the
  labels fixed server-side: real x ticks at clean seat steps (Senate 40–61 →
  every 5; House 181–325 → every 25; step chosen from range), baseline
  hairline, majority line labeled "218 = majority" (clamped away from edges),
  caption sentence moved out of the axis into the HTML caption row.
- New thin Stimulus `histogram-chart` controller layered on the served SVG:
  pointer x → nearest bar; hovered bar lifts (darker fill), tooltip from
  per-rect `data-*` strings prebuilt in ERB ("247 Dem seats · 1.9% of
  simulations · Dem majority"). ←/→ keyboard stepping, same readout.

### Cross-cutting

- Axis text 11px, `tabular-nums`, slate-500; grid hairlines solid; no
  transitions except dot radius, guarded by `prefers-reduced-motion`.
- Legends below charts stay (dataviz rule: legend always present for ≥2
  series); direct labels supplement them.
- No new JS dependencies; nothing leaves the vendored d3 set.

## Testing

- Extend `test/lib/site/charts/{timeline,polls_scatter}_test.rb` (new payload
  fields, date-label collapsing, side letters on a no-Dem race) and add
  histogram tick/label cases to `seat_histogram_test.rb` if tick math lands in
  the builder.
- One focused system test (`test/system/`, headless Chrome already wired):
  race page hover shows the timeline tooltip with a formatted dateline and the
  scatter tooltip with a pollster name; dashboard histogram hover shows a bin
  readout. Runs under `bin/rails test:system` like the pipeline test.
- Visual verification in the live dev server at desktop + 375px mobile before
  commit.

## Execution

Shared modules + importmap pin land first (one pair of hands), then three
parallel subagents — timeline / scatter / histogram — each owning disjoint
files (controller + partial + builder + tests). Integration, browser
verification, and the final commit stay with the coordinating session.
