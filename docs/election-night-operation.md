# Operating the independent election-night prototype

This feature is isolated on `codex/election-night-needle`. It does not write existing forecasts, trigger newsroom stories or send email. Collection is disabled by default. Nothing has been deployed.

## What exists

`/election-night` is a public page with separate House and Senate probability gauges, expected Democratic-caucus seats, direct versus shared race updates, raw vote coverage, source health, timestamps and assumptions. It refreshes every 30 seconds and keeps the last display if the connection fails. `/election-night/snapshot` returns the versioned snapshot with no-store caching.

CivicAPI is the primary collection path, with a pinned full-race catalog covering the complete 435-House/35-Senate board. The adapter validates each response independently; a catalog entry alone is not usable data. CivicAPI remains a secondary publisher of raw counts. It provides contest totals and reconciled county detail where available, without supplying our probabilities or turnout estimates.

Official statewide adapters cover NC, AZ, GA, VA, TX, FL, CA, WA, AR and IN county portions, LA Senate parishes, NE contest totals, AK first-choice PDF totals and MD House totals when reported. Official county additions cover portions of MI, NJ, NY and MO races. They provide fallback and independent cross-check material. These scopes differ: an official county feed does not automatically cover a whole congressional district or Senate electorate. Consult `config/election_night_sources.yml`, [source documentation](election-night-sources.md) and the dated regional audits for exact URLs and scope.

PollingDesk is a lower-priority aggregate delivery path using the **same CivicAPI upstream**, not independent corroboration. Iowa Ledger separately relays attributed official Iowa totals. Raw-result selection displays one coherent race total and never adds a district aggregate to its counties or to a publisher mirror. Healthy fallbacks take precedence over retained stale/error snapshots.

`HistoricalBaselines` loads checksum-pinned presidential counties, actual House county portions and independent county inventories from the repository. Our outstanding-vote estimator uses admitted historical anchors to show a point projection and assumption-based range for remaining **candidate votes**, including minor candidates. Contest aggregates can support labeled turnout diagnostics without becoming direct geographic evidence. See [historical provenance](../db/seed_data/election_night/README.md) and [outstanding-vote methodology](election-night-outstanding-votes.md).

The [November 3, 15:29:47 Eastern audit](research/election-night-civic-primary-coverage-2026-11-03.json) records raw sources for **470/470 races**, including **125/125 competitive races**, with CivicAPI selected for every race. It records **265 matched direct-update baselines**, including 70 competitive races, and **465 remaining-vote diagnostics**. All accepted current counts were zero; no direct observation had entered the model. A raw source, complete matched geography, turnout diagnostic and direct observation remain separate milestones.

The current pass has **492 `ok` source records out of 494**. Ohio remains rejected as test data and Alaska's official PDF still fails TLS certificate verification; the healthy primary supplies raw counts for those races. Earlier inspections also found Morris County, NJ test data and Maryland `NR` values. Missing values, test flags, failed fetches and `NR` must never be replaced with a zero-vote observation. A validated zero scaffold is a different state and still cannot move the needle. Fix the Alaska runtime certificate chain before relying on that fallback, rather than disabling verification.

No provider probabilities, expected-vote estimates or race calls are imported. Our own frozen polling prior, historical vote counts, explicitly stated turnout assumptions and the joint inference model determine the probabilities. The model is experimental, not historically calibrated.

## Local operation

Use the repository's Ruby version and installed bundle. The collector also needs `unzip` for North Carolina and `pdftotext` for Alaska's official PDF; the Docker runtime includes `unzip` and `poppler-utils`. A development or alternate production host needs the equivalent tools on its PATH. Missing PDF tooling fails the Alaska source; it must not fall back to fabricated zeroes. From this checkout:

```sh
bin/rails election_night:freeze
bin/rails election_night:sweep
bin/rails server
```

Visit `/election-night`. Freeze reads the latest completed pre-election forecast and requires 435 House plus 35 Senate races. A prior is frozen only once per storage directory. Freeze should be performed with the final intended pre-election polling run, after checking candidate/caucus mappings and current district baselines.

**The archived development integration check used an October 21 prior.** That timestamp is retained in its snapshot. It was suitable for an integration check, not a November 3 launch prior. Inspect the actual frozen prior's date; do not publish an old verification snapshot as a current election-day forecast.

For a separate experiment, set an absolute `ELECTION_NIGHT_STORAGE` path consistently for freeze, sweep, web and worker. The default is the ignored `storage/election_night` directory. Do not replace an existing prior in place; use a new directory and retain the old experiment for audit.

For recurring operation after deployment review, set `ELECTION_NIGHT_ENABLED=true` on the worker and restart it. This enables a GoodJob sweep every three minutes. Leave it unset to keep the feature manual. The existing polling-model and newsroom schedules are unchanged. Ensure the worker processes the `election_night` queue.

The collection policy is explicit:

| Path | Priority | Minimum interval | Execution |
| --- | ---: | ---: | --- |
| CivicAPI full-race catalog | 0 | 180 seconds per endpoint | At most two simultaneous requests |
| Official fallback feeds | 10 | 600 seconds | Sequential large exports |
| Iowa Ledger fallback | 20 | 180 seconds | Sequential |
| PollingDesk fallback | 30 | 300 seconds | Sequential |

Source intervals still apply within scheduled sweeps. The process lock prevents overlapping passes; a three-minute schedule does not guarantee a complete national refresh every three minutes. A slow full pass can outlast that interval, and an unchanged report can be fetched successfully. Measure full-sweep duration from the intended hosting network and monitor repeated failures without increasing concurrency or bypassing publisher limits.

In the current live pass, the 470 primary fetch timestamps spanned **15:25:24–15:29:36 Eastern**, approximately **252 seconds**, before the snapshot published at 15:29:47. A full-board pass can therefore exceed the three-minute scheduler interval. The single-writer lock prevents a second pass from overlapping, and readers keep the previous atomic snapshot until the next publication. Background collection remains disabled by default; this audit did not enable it.

## Storage and concurrency

- One process holds an OS file lock for an entire collection/inference/publication pass. A competing invocation exits instead of overlapping.
- Raw response bodies are stored by SHA-256, with source/election metadata and original timestamps. Companion metadata and version responses have their own archived hashes. Corrected totals replace the current normalized snapshot; earlier raw versions remain available.
- Indiana's settings select the current A/B result file. Clarity county sources resolve a current version token, then fetch both summary and settings from that same version. Keep the resolved download URL, version hash, metadata hash and raw hash together; changing only a cached URL can mix elections or report generations.
- Historical baseline bodies and hashes are frozen in the source record. A newly added current-results adapter does not automatically supply historical geography or authorize a direct model update.
- The nationwide historical dataset is frozen separately in `db/seed_data/election_night`. Preserve its manifest revision with the model inputs; do not regenerate it during a live sweep. An invalid checksum, race identity or vote sum fails validation. Incomplete state inventories remain explicitly unverified and cannot supply a complete Senate manifest.
- Normalized source records carry a parser version. Changing normalization invalidates cached results and baselines; raw archives stay intact. This prevents pre-fix county names or validation rules from silently surviving a code update.
- `latest.json` is published by atomic rename after a complete model calculation. Each model snapshot is also retained in `history/` with input hashes and the measurements used.
- The web and worker must mount the **same persistent filesystem directory**. This implementation is not a multi-host object-store publisher. Do not assume unrelated container filesystems share snapshots.
- Failed source requests retain previously validated data with its original retrieval timestamp and an explicit error/stale status. A transient outage does not erase counted votes. A model using such a source is labeled stale. Failed inference leaves the previous public snapshot untouched.
- Fetch time and publication time are separate. A successful fetch can return an unchanged report; some publishers supply no reliable report timestamp. Nebraska's export-generation time is not a new vote update. National CSVs may have race-specific update times, so a fresh row for one race must not make another look current. Monitor long-unmoved reports during counting; the collector cannot prove that officials have finished counting.
- Some raw exports are tens of megabytes; provision disk for archived revisions, and use a dedicated collector resource budget rather than assuming the existing small host has ample headroom. Enhanced Voting and Arkansas release unused precinct descendants while validating JSON, and North Carolina streams rows instead of retaining local contests. Content hashes avoid duplicate copies of identical bodies. There is no destructive retention task. Performance measurements from the earlier, smaller registry do not establish the expanded collector's memory or timing requirements.

PollingDesk's CSV has no explicit election-date or test-data columns. Its adapter is pinned to the inspected 2026 general-election catalog, validates the cycle/race/candidate scaffold and CivicAPI attribution, and exposes aggregate raw totals only. Keep its configured priority below CivicAPI and official fallback feeds. Recheck the catalog context if its publisher changes the feed; archive provenance instead of treating retrieval time as election-date proof. Matching CivicAPI and PollingDesk totals do not constitute two-source verification.

## Direct conditioning gates

The current county scaffold must exactly match an independently complete historical manifest. Senate uses the full state county inventory, checked by the historical loader against Census rosters with documented reporting exceptions; an independently validated official statewide manifest remains a fallback where appropriate. The county rows for one race must come from **one coherent publisher snapshot**. Do not combine a partial primary report with overlapping counties from another timestamp or publisher. A complete fallback snapshot can be selected separately. Every component must have a usable historical baseline.

House races additionally require independently verified unchanged district boundaries and an exact match to the historical district's county-portion manifest. Counting one current House contest in a county does not prove that county is unsplit: another contest could simply be omitted. Whole-county presidential baselines cannot supply a split district's historical vote. Current-line presidential contest aggregates support turnout diagnostics only and cannot satisfy this gate.

The historical House race as a whole must give each major party at least 5% of its all-candidate votes; an individual strongly partisan county remains valid evidence. A two-party matchup must have at least 5,000 counted two-party votes, at least 50% represented historical geography and a **lower counted-fraction bound of at least 15%**, calculated using the scenario range's upper projected-turnout bound, before its returns create a measurement. The vote thresholds and representation weights use Democratic plus Republican votes; turnout projections and final margins use **all candidate votes**. These are operating assumptions, not observed reporting-completion facts.

Only verified complete 2022 Senate county totals are currently admitted as midterm turnout anchors. A matching 2022 House county name does not prove that its district portion has the same boundaries, so those totals remain withheld from the automatic anchor path. Without an admitted anchor, the fallback is 75% of matching 2024 all-candidate votes, with wider uncertainty. Projected remaining votes are never an official ballot inventory. The point keeps an explicit unresolved tail above counted votes and expands when counts exceed the original anchor; it is not a conditional distribution mean and must not be labeled “votes known to remain.” The range combines shared and local turnout and reporting-order scenarios. Reaching the historical anchor never creates a call or 100% completion.

There is a substantial uncertainty term for within-county reporting order, turnout and early/mail composition. The joint model also includes an observation-only state reporting-bias factor, so many races sharing an early batch cannot average that bias away. See `docs/election-night-model.md` for equations and limits.

Ranked-choice and independent matchups do not receive direct updates in this version. Alaska's PDF contains first-choice counts, not transfers or final ranked-choice outcomes. Aggregate-only sources and isolated official counties do not supply missing statewide geography. CivicAPI county reconciliation likewise does not replace an independent race manifest or matched historical baseline. In particular, a zero-valued county subset also sums to a zero contest total and is not accepted as proof of complete county coverage. These sources can display raw counts while races retain prior uncertainty or respond to shared evidence from other races. Changed districts without matching history remain outside direct conditioning. Expanded raw coverage leaves all of these model gates unchanged.

## Verification and audits

Dated source audits under `docs/research/` distinguish inspected official files, county portions, secondary aggregates, zero scaffolds, `NR`, test payloads and inaccessible routes. They record URLs, election identity, hashes and local samples. A registered URL, successfully parsed body, available raw race total, complete historical manifest and actual direct measurement are separate milestones; report their counts separately after running the final registry.

The current [Civic-primary coverage audit](research/election-night-civic-primary-coverage-2026-11-03.json) records selected raw source/scope, independently matched historical geography and turnout diagnostics for the same snapshot, with its complete Civic catalog, frozen watchlist, historical revision and input hashes. Selected raw coverage comprises 290 county-level and 180 contest-level races; the competitive subset is 72 county-level and 53 contest-level. The 465 remaining-vote diagnostics comprise **289 county estimates and 176 contest estimates**; **14 Senate races** use verified 2022 turnout anchors. These scopes describe different outputs and must not be conflated.

The older [coverage CSV](research/election-night-coverage-2026-11-03.csv) and [coverage audit](research/election-night-coverage-audit-2026-11-03.json), associated with the 14:43:29 Eastern run, remain **prior-audit artifacts**. Their coverage and timing counts are superseded for the current collection strategy.

The current application suite passed **1,609 tests and 6,848 assertions**. Rails autoload validation and lint for **59 election-night Ruby files** also passed. These checks establish implementation behavior, not electoral calibration.

A **normalized-source-cache replay** reproduced identical race and chamber outputs with 10,000 joint simulations in **8.693 seconds**, without network requests. This replays validated normalized inputs; it is not a fresh raw-response reparse or a cold-network benchmark. No new peak-memory measurement is claimed. Previous mobile checks and network/RSS timings remain archived evidence for the narrower registry. Reproducibility establishes determinism, not historical calibration or live-election accuracy.

The earlier `docs/research/election-night-integration-check-2026-11-03.json` records an explicitly synthetic Republican-overperformance scenario and its stale development prior. It verifies response direction, not live returns or historical calibration. Earlier source counts, test totals and memory benchmarks describe that narrower implementation and must not be presented as validation of the expanded registry.

Tests cover election metadata, version binding, the complete primary catalog, bounded collection concurrency, source priority, test rejection, missing values, vote-method reconciliation, duplicate candidates, fusion lines, county/summary double counting, last-good evidence, independent historical inventories, redistricting exclusions, turnout overshoots, all-candidate denominators, deterministic inference, shared uncertainty, independent caucuses and UI refresh behavior. Re-run the applicable checks after further source, model or presentation changes. Benchmark cold live-network duration separately from local parsing and inference. Browser demonstrations must remain clearly labeled and isolated from the collector's real snapshot.

## Before public operation

Capture a fresh, complete pre-election prior; verify nominees, uncommitted caucuses and election IDs; run the full collector from the intended hosting network; provision shared persistent storage and adequate memory/disk; inspect source scope, upstream attribution and timestamps; and verify the first nonzero batches against the linked official pages where available. For sources sharing CivicAPI, use independent evidence for cross-checks rather than counting two delivery paths twice. These are operational requirements, not deployment actions completed by this branch.

The largest product limitations are uneven direct official access, shared secondary upstreams, incomplete historical model coverage, county-level rather than ballot-method-conditioned inference, uncertain turnout, and no historical night-by-night calibration. Broad raw-result availability does not remove those limits. A working needle must not be described as equivalent to a mature national election-night forecasting operation.
