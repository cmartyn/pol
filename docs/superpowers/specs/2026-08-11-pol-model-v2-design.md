# pol model v2 — coverage, house effects, correlated error

**Status:** Approved by Chase 2026-08-11. Successor to `2026-08-10-pol-mvp-one-shot-design.md` (MVP, merged to main at `1b3400a`).

Three phases, executed in pipeline order — ingestion → averaging → simulation — so each layer's goldens are re-pinned once, against the layer beneath it already settled.

## Why these three

The MVP's House side is its weak half and its published numbers say so. `/house` currently carries a caveat telling readers the model is too confident, every one of the 435 district forecasts is fundamentals-only (zero district polls in the database), and the polling average treats every pollster as unbiased. Phases 8–10 close all three, in the order that keeps the model honest at each step.

## Approved decisions

1. **Regions = the 9 US Census divisions**, not the 4 census regions. A "South" spanning Florida to Texas is too coarse to carry a shared error term. Verify the state→division mapping against census.gov at build time.
2. **Calibration preserves our AAPOR-derived Senate totals** and back-solves the idiosyncratic terms. Variance is reallocated from independent to correlated channels, not invented. (One documented exception below: the House district total rises, because `sigma_district: 6.0` is 538's own cited district-level value and our 6.50 total was never independently calibrated — it was an artifact of having only one correlated term.)
3. **House effects adjust the average and are published.** Shrunk toward zero by poll count, capped, and every pollster's estimated effect + sample size shown on a public `/pollsters` page. An adjustment readers cannot inspect is the secret sauce this project promised not to have.

---

## Phase 8 — Data coverage (ingestion)

**8a. District-level polls.** Verify first, via the live encyclopedia, where 2026 US House district polling actually lives (candidates: a consolidated "2026 United States House of Representatives elections" polling section, per-state election pages, per-district pages for marquee races). Scrape what genuinely exists, through the existing `Ingest::RecordPoll` single door, with the same provenance and dedup contract. Race matching is by district slug; rows that cannot be confidently matched are skipped and counted, never guessed. **If 2026 district polling is genuinely sparse or absent, that is the finding** — record the pages checked and what they contained in BUILD_NOTES rather than manufacturing coverage.

**8b. Refusal observability (closes the ledgered Phase 2 minor).** Today a source that yields nothing is recorded as `succeeded, fetched 0` whether the page has no polling section at all or the parser refused a table it should have read — the two are indistinguishable, so a race can go dark silently. `ScrapeRun` gains a refused-table count and a machine-readable refusal reason (no polling section / table layout unrecognized / no candidate-column match / primary-only table). The admin scrape-health page surfaces refusals prominently and treats "refused ≥ 1" as its own status, distinct from a clean empty page.

**8c. Dark-race audit.** Eleven Senate races hold zero polls (CO, DE, IL, LA, NJ, NM, OK, OR, TN, WV, WY). Four were hand-checked during the MVP build (NJ, OR, TN have no polling section; CO's only table is a Democratic primary, correctly refused). Verify the remaining seven — DE, IL, LA, NM, OK, WV, WY — against live pages and record the finding per race in BUILD_NOTES. Any that turn out to be parser failures are bugs to fix here.

## Phase 9 — Pollster house effects (averaging)

**Estimation.** A pollster's house effect is its weighted mean signed residual against the contemporaneous average of the same quantity — computed primarily from the generic-ballot corpus (559 polls, 79 pollsters, one quantity, the clean basis), with race-level residuals as a secondary source where a race has enough distinct pollsters to define a meaningful average. Residuals are time-decayed so a house effect reflects the pollster's recent behavior.

> **Amended 2026-08-12 — residual half-life, ratified by Chase.** This originally specified decay "on the same half-life as the averager" (14 days). Implementation used a separate `residual_half_life_days: 180`; the deviation was reviewed, swept against the live corpus, and is ratified. The reasoning: the averager's 14-day half-life is tuned for a fast-moving quantity — where a race stands *now* — while a house effect is a slow-moving property of a firm's methodology. At 14 days, RMG Research's 24 polls carry roughly 1.4 polls of effective information while the shrinkage term, which counts raw polls, sees 24 and barely shrinks — a confident-looking adjustment resting on one recent poll's sampling error. The sweep shows three firms binding the ±3-point cap at 14 and 30 days against one from 60 days out, with 180 inside that plateau. It stays a dial rather than a cliff (RMG reads −2.25 at 60 days, −2.84 at 180, −2.98 at 365), so the constant is published on the methodology page with its reasoning like every other number. The alternative lever — shrinking on effective sample size rather than raw poll count, keeping 14 days — was available and is recorded here as the road not taken.

**Shrinkage and caps.** Raw effects are shrunk toward zero by sample size — `effect × n / (n + k)`, `k` in params — because 71 of 134 pollsters have fewer than three polls and their raw residuals are noise. The shrunk effect is then clamped to a maximum magnitude (params). Both constants documented on the methodology page like every other.

**Application.** The shrunk, capped effect is subtracted from a poll's margin before it enters the average. Recomputed as part of each model run, stored so a forecast's inputs are reproducible, and never applied to a poll whose pollster has fewer than the minimum poll count (params).

**Publication.** A new public `/pollsters` page: every pollster, poll count, estimated house effect with its sign convention stated plainly (D+ means the pollster leans Democratic relative to the field), whether the effect is being applied, and the shrinkage that was applied to it. Linked from the methodology page.

## Phase 10 — Correlated error structure (simulation)

Replace the single national error term with four components. Every simulated world draws one national error, one per census division, one per state, then per-race idiosyncratic noise:

| Component | Shared by | σ | Source |
|---|---|---|---|
| National | every race, both chambers | 3.0 | 538 2024 House model |
| Regional | every race in a census division | 2.0 | 538 |
| **State** | **a state's Senate race and all its districts** | **2.0** | 538 |
| Idiosyncratic — Senate polled | one race | 2.29 | back-solved |
| Idiosyncratic — Senate unpolled | one race | 7.30 | back-solved |
| Idiosyncratic — House district | one district | 6.0 | 538 |

**The state term is the structural gain.** Today a state's Senate race and its House districts are correlated only through the national environment; a shared state error is what makes a bad night in Georgia a bad night for Georgia's Senate race *and* its districts together.

**Back-solving preserves the Senate calibration.** Correlated total = `sqrt(3² + 2² + 2²) = 4.123`. Senate polled total stays at today's AAPOR-calibrated `4.717` → idiosyncratic `sqrt(22.25 − 17) = 2.291`. Senate unpolled stays at `8.382` → `sqrt(70.25 − 17) = 7.297`. House district keeps 538's `6.0`, so its total rises `6.50 → sqrt(53) = 7.28`, toward 538's `7.55` — documented as a deliberate move to better-evidenced ground, not a silent widening.

**Omitted, and said out loud:** 538's fourth correlated component, 2.0 at the demographic-cluster level, needs cluster data we do not have. We are therefore marginally narrower than 538 (4.12 correlated against their 4.58) and the methodology page says so.

**Expected effect,** interpolating the Phase 3 measurement table (2.5 → 96.3%, 3.5 → 90.2%, 4.58 → 83.9%): House control lands near 85–88%, Senate near 36–37%. The blanket House overconfidence caveat comes off `/house`, the dashboard, the newsroom prompts and the rake summary, replaced by a smaller, accurate note naming the cluster term as the remaining gap. Time multiplier applies to all components as today.

**Verification is not optional here.** Fixed-seed goldens re-pinned; the cross-chamber shared-N regression test extended to cover the new state term (a state's Senate race and its districts must co-move); a test proving reallocation is not inflation (per-race Senate margin distribution unchanged in width while the seat distribution widens); and the live before/after board recorded in BUILD_NOTES.

---

## Global constraints (unchanged from the MVP)

Params-as-data with citations, methodology renders from the YAML, minitest + fixtures, WebMock with zero live HTTP in the suite, rubocop clean, no new gems, never print credentials, nothing destructive against the development database (it holds the real scraped corpus and the site's published dispatches). Logical commits per phase, suite green at each.
