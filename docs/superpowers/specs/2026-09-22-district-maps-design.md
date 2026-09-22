# District and state maps

**Date:** 2026-09-22 · **Status:** approved for implementation (brainstormed with the user; execution delegated to Grok 4.7 subagents with review between waves)

## Goal

Add maps to the public site: a national Senate map, a national House district
map, a locator on each Senate race page, a state district map on each House
race page, and small versions of both national maps on the dashboard's chamber
cards. Nothing geographic is committed to git — not the maps, not the
boundaries, not even test fixtures. Boundaries are fetched once from the
Census Bureau at runtime and stored in Postgres; every SVG is drawn from them
at render time.

## Decisions (user-confirmed)

- **Scope:** all five surfaces above.
- **House national graphic:** the real geographic district map (all 435),
  not a cartogram — a cartogram needs a layout, and a hand-authored layout is
  exactly the hard-coding this project avoids. Small urban districts are
  handled by nearest-centroid hover snapping; the /house table remains the
  path to every seat.
- **House race page:** every district in the state shaded by its own
  forecast, the page's district drawn with a heavy outline, neighbors
  clickable.
- **Architecture (approach A):** store Census geometry (simplified lon/lat) in
  a `boundaries` table; project, simplify and color in Ruby at render time,
  inside fragment caches. Rejected: B (store finished SVG paths — every size
  or projection tweak would need a refetch, for a render-time saving the
  fragment cache already provides) and C (SVG files on the Docker volume,
  colored client-side — the volume isn't in the nightly backup, no-JS readers
  would see gray maps, and it breaks "the payload carries the words").
- **Color ramp:** a default ramp (below); the user chose not to hand-write it.

## Data source (verified live on 2026-09-22)

All from the Census Bureau's TIGERweb ArcGIS REST API, `f=geojson`,
`outSR=4326`, simplified server-side with `maxAllowableOffset`:

| What | Service | Layer (looked up by name) | Why |
|---|---|---|---|
| State outlines | `Generalized_ACS2025/State_County` | `States 500K` | Cartographic boundary: clipped to the shoreline (Michigan is 111 polygons, not one blob over Lake Michigan) |
| District lines | `TIGERweb/Legislative` | `120th Congressional Districts` | The lines in effect for the 2026 election, including the ten states that redrew mid-decade (AL, CA, FL, LA, MO, NC, OH, TN, TX, UT) |

- **Layer ids are resolved by name at fetch time** from `MapServer?f=json`;
  TIGERweb renumbers layers each release.
- **The Congress number is derived from the cycle:** `((cycle − 1788) / 2) + 1`
  = 120 for 2026. It names the layer (`"120th Congressional Districts"`) and
  the district field (`CD120`).
- **FIPS → postal comes from the state layer's own `STATE`/`STUSAB` fields** —
  no FIPS table in code. States kept: `Race::STATE_NAMES.keys` (50 + DC).
- **District codes:** `"00"` (at-large) → district 1, the app's existing
  convention (`HouseCandidatesParser::AT_LARGE_DISTRICT`); `"01".."53"` →
  integer; `"98"` (delegate) and `"ZZ"` (water-only) are dropped.
- **Per-state detail:** each state's outline and districts are requested with
  `maxAllowableOffset = state longitude span / 2000`, so Rhode Island gets
  ~40 m detail and Texas ~7 km, both about half a pixel on a 600 px state map.
- **The date line:** stored longitudes are made continuous — a positive
  longitude (only the far Aleutians) is stored as `lon − 360`. Spans, bounding
  boxes and fitted projections then need no special case.

TIGER legal district polygons extend into water (Great Lakes, bays, 3-mile
coastal belt). They are clipped at render time by an SVG `<clipPath>` of the
state's shoreline-clipped outline — no geometry library needed.
Prototype-verified on the full national map: Michigan's peninsulas, the
Chesapeake, Long Island Sound, and Cape Cod all render correctly.

## Storage

`boundaries`: `state` (2-letter, same as `races.state`), `district` (integer,
null for a state outline — the same shape as `races`), `geometry` (jsonb
GeoJSON geometry, lon/lat, 5 decimals), `source_url`, timestamps. Uniqueness
on (state, district) via two partial unique indexes (outline rows / district
rows), which works on every Postgres version in play.

Written by `bin/rails pol:seed_boundaries` (`Ingest::BoundarySync`), which is
idempotent and takes about two minutes (1 + 51 × 2 polite requests):

- It refuses to half-succeed, like `pol:seed_races`. It raises `IncompleteSource`
  and writes nothing unless:
  - there is one outline per expected state;
  - there are exactly `HOUSE_DISTRICTS` (435) districts;
  - each state's district count matches its House races.
- It replaces the table in one transaction (`delete_all` + `insert_all!`), so
  readers see the old set until commit and `collection_freshness` changes
  after every successful run.
- Expected size: 2–3 MB of jsonb.

Until it has run, every map partial renders nothing; pages never error.

## Rendering

**Projection** (`Site::Maps::ConicEqualArea`, pure Ruby, no gems). This is
d3-geo's `geoConicEqualArea` math, verified against d3 to 1e-9 at eight
reference points including the Alaska inset and Attu (+173.2°).

- **National maps:** d3's `geoAlbersUsa` constants. The lower 48 use parallels
  29.5/45.5, rotate 96, center (−0.6, 38.7); Alaska uses scale ×0.35 and
  Hawaii its own conic, translated into d3's standard inset positions. The
  sub-projection is chosen by the boundary's state (AK, HI, else lower 48),
  not by clip extents.
- **State maps:** a conic fitted to the state. Rotate = −(center longitude);
  standard parallels at 1/6 and 5/6 of the state's latitude range. So Maine
  isn't drawn rotated 16° as it would be on a national projection.

**Frame and simplification** (`Site::Maps::Path`, `Site::Maps::Canvas`):
- Projected points are fitted into the map's width (960 national, 600 state)
  with the height following the aspect ratio.
- Points are simplified with Douglas–Peucker in pixel space (0.5 px for the
  full-size maps, 1.0 px for dashboard and locator sizes). Rings smaller than
  the tolerance are dropped, but a boundary never vanishes entirely. If every
  ring is sub-pixel, as with Manhattan's districts on the national map, its
  largest ring is kept unsimplified, so hover snapping and keyboard stepping
  can still reach it.
- Paths use relative coordinates at 1 decimal, computed from rounded absolute
  positions so they cannot drift, with `fill-rule="evenodd"` for holes.
- Measured on real data at 0.5 px: the national House map is about 173 KB raw,
  61 KB gzipped.

**Payload** (unified across builders, so one partial renders all of them). The
payload carries the words; the view only places them.

```ruby
{
  key: "house",                     # unique per map on a page; prefixes every SVG id
  view_box: "0 0 960 593",
  aria_label: "...",
  interactive: true,                # false: no links, no tooltips, no controller (locator)
  groups: [
    { state: "RI",
      clip_id: "house-clip-RI",     # nil when shapes ARE the outlines (Senate)
      outline_id: "house-outline-RI",
      outline_d: "M…z",
      shapes: [Site::Maps::Shape],
      highlight_d: "M…z" or nil }   # heavy outline, drawn inside the group's clip so a
                                    # coastal district's highlight never outlines water
  ],
  legend: { ramps: [...], swatches: [...], caption: "..." }
}

Shape = Struct(:key, :d, :slug, :cx, :cy, :fills, :tips)
  # fills: { excl_internals: "#rrggbb", incl_internals: "#rrggbb" }
  # tips:  { excl_internals: { header:, subheader:, rows: [{ value:, label:, party:, swatch: }], footer: },
  #          incl_internals: ... }  — nil for non-interactive shapes
```

Tooltips do not ride in per-shape `data-*` attributes. Per shape, two
variants of JSON with HTML-escaped quotes would roughly double the House map.
Each interactive map instead carries one
`<script type="application/json">` of `{ shape key => tips }`, emitted with
`json_escape`. It is very repetitive, so it compresses to a few KB. Rows name
a `party`, not a color; the controller maps party to hex through
`charts/theme.js`, the one place chart JavaScript knows a color.

**Builders:**
- `Site::Maps::SenateMap.build`: every state outline is a shape. It is filled
  by its Senate race, or `NO_RACE` if there is none. If a state has two races,
  it is filled by the more competitive one and the tooltip names the other.
  `SenateMap.build(highlight: race)` gives the non-interactive locator: only
  that state is colored, and it gets a heavy outline.
- `Site::Maps::HouseMap.build`: one group per state. Its districts are clipped
  by the state outline, and the outline is stroked on top.
- `Site::Maps::StateMap.build(race)`: one state's districts at 600 px wide
  (max height 440), with the race's district as the group's `highlight_d`.
- Builders iterate boundaries, not races. A race without a boundary is simply
  not drawn, and a boundary without a race is filled `NO_RACE`/`NO_FORECAST`
  rather than failing.

**Color** (`Site::Maps::Palette`):
- The party hues are the ones in `charts/theme.js`: Democratic `#1d4ed8`,
  Republican `#b91c1c`, other `#64748b`.
- The leading side is `Site::Format.leader` (new; `rating_word` is refactored
  onto it). The mix toward its hue is m = 0.2 + 0.8 · clamp((p_lead − 0.5) / 0.5, 0, 1),
  blended with white in sRGB.
- Uncontested seats get full party color. No forecast is `#d4d4d4`
  and no race is `#e5e5e5`: neutral grays, because slate's blue cast reads as the palest Democratic tint.
- The legend has two ramps (Dem, Rep) and swatches for no forecast and no race.
  Its caption states the tossup band from `site.tossup_band_pp`.
- The vocabulary stays the site's own: "Tossup", "Favors Dem", "Uncontested".

**Tooltips:**
- The header is `race.name`, and the subheader is the rating word ("No
  forecast yet" when there is none).
- Rows list each nonzero win probability, sorted descending, as `"62%"` +
  `"Dem"`/`"Rep"`/`"Other"`. These are the timeline tooltip's names.
- A final row gives the margin: `Site::Format.margin(mean_margin, …)` with the
  label "estimated margin". House races use dem/rep sides; Senate races use
  `Site::RaceSides.for(candidates)`.

**Internals toggle:**
- Each shape is drawn once, with `style="--fill-excl:…;--fill-incl:…"`.
- `application.css`: `.map-shape { fill: var(--fill-excl) }` and
  `html[data-internals="on"] .map-shape { fill: var(--fill-incl) }`.
- The tips JSON holds both variants per shape. The controller reads
  `html[data-internals]` at show time and re-renders an open tooltip on the
  toggle's `internals:changed` event.
- With no JavaScript, readers see the published variant.

**Interaction** (`map_chart_controller.js`, reusing `charts/tooltip.js`):
- Each shape is an SVG `<a href>` (with `tabindex="-1"`), so clicks work
  without JavaScript.
- When the pointer is over a shape, that shape is shown. Otherwise the pointer
  snaps to the nearest shape centroid within 24 px.
- The wrapper is focusable. ←/→/Home/End step through shapes in DOM order
  (state, then district: the tables' default order), Enter opens the race, and
  Esc or blur clears.
- The tables stay the complete keyboard path to every race.

## Pages and caching

- **/senate and /house:** the map sits between the chamber card and the table.
  Its fragment is keyed on `@latest_run`,
  `collection_freshness(Boundary.all)`, and the chamber's
  `collection_freshness(Race.senate|house)`.
- **Race page:** the locator (Senate) or state map (House) goes in the header
  row's empty right side and stacks below on mobile. `race-core`'s key gains
  `collection_freshness(Boundary.all)`.
- **Dashboard:** the chamber card gains a `map:` local (default false). Only
  `home/index` passes true, so /senate and /house don't show the map twice.
  The card's key gains the flag and boundary freshness.
- **Methodology:** "Where the data comes from" gains a paragraph naming the
  Census source and the 2026 lines.
- **Edge cache:** unaffected. Pages stay byte-identical for every reader.

## Testing

Offline, like the rest of the suite (WebMock blocks the network).

- **No real geometry in git.** `TigerwebStubHelper` builds TIGERweb-shaped
  responses from made-up rectangles in Ruby, and `BoundaryFactory` creates
  rectangle `Boundary` rows.
- **Unit tests:**
  - projection against the d3 reference values;
  - simplification, path encoding (exact strings, no drift), and centroids;
  - the canvas fit;
  - palette endpoints and the ramp;
  - each builder: both variants, uncontested, missing forecast, no race,
    highlight, at-large, and races without boundaries;
  - the fetcher: layer by name, derived Congress number, per-state offsets,
    code mapping, date-line normalization, refusals writing nothing, and
    re-runs replacing.
- **System test:** hovering the Senate map shows the tooltip; flipping the
  internals toggle changes the computed fill.
- **Existing guards must keep passing:** the /house query count must not scale
  with districts, and the fragment-reuse tests must still pass.
- **Visual check (orchestrator):** real Census boundaries seeded into
  development, checked at desktop width and at 375 px.

## Rollout

Deploy, then run `bin/kamal app exec 'bin/rails pol:seed_boundaries'` once.
Re-run it only if the Census Bureau corrects the lines (a court-ordered
redraw), or for the 2028 cycle. Then the derived Congress number moves to 121
and the layer lookup fails loudly until TIGERweb publishes that layer.

## Execution

- **Wave 0 (orchestrator):** create a feature branch. Let `POL_TEST_DATABASE`
  override the test database name, so parallel worktrees don't share
  `pol_test`.
- **Wave 1 (two Grok 4.7 agents in parallel, separate worktrees):**
  - the data layer (`Boundary`, `Ingest::TigerwebClient`,
    `Ingest::BoundarySync`, the rake task, test helpers);
  - the geometry math (`Site::Maps::ConicEqualArea`, `Projection`, `Path`,
    `Canvas`).

  They share no files. The math depends only on a duck type (`#state`,
  `#rings`).
- **Wave 2 (Grok):** `Site::Format.leader`, the palette, `Shape`, and the three
  builders.
- **Wave 3 (Grok):** the partials, Stimulus controller, CSS, /senate and
  /house wiring, and the system test.
- **Wave 4 (Grok):** the race pages, dashboard, methodology, and docs.
- **Between waves, the orchestrator:** reviews the diff, runs `bin/ci`, merges.
  At the end: seeds real boundaries and does the browser check.
