// The one place chart JS is allowed to know a color. Party hues match the
// site's Tailwind text conventions (blue-700 / red-700 / slate) so a chart
// mark and the prose beside it can never disagree about what Dem-blue is.
// The set was checked with a CVD validator: worst adjacent pair ΔE 14.6
// (target ≥ 8), all ≥ 3:1 against white. Slate for ind/other is deliberately
// low-chroma — it is the de-emphasized "everything else" channel, always
// backed by a legend or direct label, never an identity slot of its own.
export const PARTY = {
  dem: "#1d4ed8",
  rep: "#b91c1c",
  ind: "#64748b",
  other: "#64748b"
}

export function partyColor(party) {
  return PARTY[party] || PARTY.other
}

// The polls-scatter average reference line (amber-600) and its on-chart
// label (amber-700 — darker because 11px text needs more contrast than a
// 1.5px line).
export const AVERAGE = { line: "#d97706", text: "#b45309" }

// Chart chrome: recessive slates for everything that isn't data.
export const CHROME = {
  axisText: "#64748b",   // slate-500
  grid: "#f1f5f9",       // slate-100 — solid hairlines, never dashed
  baseline: "#cbd5e1",   // slate-300 — axis base / zero lines
  band: "#f1f5f9",       // tossup band fill
  bandText: "#94a3b8",   // slate-400 — in-band label
  crosshair: "#94a3b8",  // slate-400 — hover hairline
  threshold: "#475569",  // slate-600 — majority/threshold lines
  ring: "#ffffff",       // surface ring around dots
  fontSize: 11           // px — axis and annotation text, fixed at any width
}
