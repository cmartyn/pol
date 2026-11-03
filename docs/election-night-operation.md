# Operating the independent election-night prototype

This feature is isolated on `codex/election-night-needle`. It does not write existing forecasts, trigger newsroom stories or send email. Collection is disabled by default. Nothing has been deployed.

## What exists

`/election-night` is a public page with separate House and Senate probability gauges, expected Democratic-caucus seats, direct versus shared race updates, raw vote coverage, source health, timestamps and assumptions. It refreshes every 30 seconds and keeps the last display if the connection fails. `/election-night/snapshot` returns the versioned snapshot with no-store caching.

The collector has official statewide adapters for NC, AZ, GA, VA, TX, FL, CA, WA, AR and IN county portions, LA Senate parishes, NE contest totals, AK first-choice PDF totals and MD House totals when reported. Official county additions cover portions of MI, NJ, NY and MO races. These scopes differ: an official county feed does not automatically cover a whole congressional district or Senate electorate. The registry controls which sources are enabled; consult `config/election_night_sources.yml`, `docs/election-night-sources.md` and the dated regional audits for exact URLs and scope.

CivicAPI full-race responses provide secondary contest totals and reconciled county detail where available. PollingDesk is a lower-priority aggregate delivery path using the **same CivicAPI upstream**, not independent corroboration. Iowa Ledger separately relays attributed official Iowa totals. Raw-result selection displays one coherent race total and never adds a district aggregate to its counties or to a publisher mirror.

The November 3 **14:43:29 Eastern** integration snapshot has raw sources for **470/470 races** and **125/125 competitive races**. Selected competitive coverage is **65 county-level and 60 contest-level**, with 68 official and 57 secondary sources. All accepted counts were zero; **44 races have direct historical baselines**, including 16 competitive races, and none yet has a direct observation. These are pre-poll coverage measurements, not evidence that every race can move the model directly.

The inspected Ohio feed and Morris County, NJ version are test data and cannot become live counts. Maryland `NR` means not reported: the affected contest remains unavailable. Missing values, test flags, failed fetches and `NR` must never be replaced with a zero-vote observation. A validated official zero scaffold is a different state and is still insufficient evidence to move the needle.

In that final run, 82 of 84 source records parsed successfully. Ohio remained rejected as test data, and Alaska's official PDF request failed TLS certificate verification (`unable to get local issuer certificate`). Resolve the runtime certificate chain before relying on that path; do not disable verification. Maryland's successful response contained only `NR` for its House contests and supplied no counts. California recovered from a timeout and St. Charles succeeded after its encoding correction. Secondary raw feeds filled the displayed gaps.

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

The expanded registry increases network work per sweep. Source minimum intervals still apply, and the process lock prevents overlapping passes; the scheduler interval does not guarantee that every publisher updates that often. Measure full-sweep duration from the intended hosting network and monitor slow or repeatedly failing sources before relying on unattended operation.

## Storage and concurrency

- One process holds an OS file lock for an entire collection/inference/publication pass. A competing invocation exits instead of overlapping.
- Raw response bodies are stored by SHA-256, with source/election metadata and original timestamps. Companion metadata and version responses have their own archived hashes. Corrected totals replace the current normalized snapshot; earlier raw versions remain available.
- Indiana's settings select the current A/B result file. Clarity county sources resolve a current version token, then fetch both summary and settings from that same version. Keep the resolved download URL, version hash, metadata hash and raw hash together; changing only a cached URL can mix elections or report generations.
- Historical baseline bodies and hashes are frozen in the source record. A newly added current-results adapter does not automatically supply historical geography or authorize a direct model update.
- Normalized source records carry a parser version. Changing normalization invalidates cached results and baselines; raw archives stay intact. This prevents pre-fix county names or validation rules from silently surviving a code update.
- `latest.json` is published by atomic rename after a complete model calculation. Each model snapshot is also retained in `history/` with input hashes and the measurements used.
- The web and worker must mount the **same persistent filesystem directory**. This implementation is not a multi-host object-store publisher. Do not assume unrelated container filesystems share snapshots.
- Failed source requests retain previously validated data with its original retrieval timestamp and an explicit error/stale status. A transient outage does not erase counted votes. A model using such a source is labeled stale. Failed inference leaves the previous public snapshot untouched.
- Fetch time and publication time are separate. A successful fetch can return an unchanged report; some publishers supply no reliable report timestamp. Nebraska's export-generation time is not a new vote update. National CSVs may have race-specific update times, so a fresh row for one race must not make another look current. Monitor long-unmoved reports during counting; the collector cannot prove that officials have finished counting.
- Some raw exports are tens of megabytes; provision disk for archived revisions, and use a dedicated collector resource budget rather than assuming the existing small host has ample headroom. Enhanced Voting and Arkansas release unused precinct descendants while validating JSON, and North Carolina streams rows instead of retaining local contests. Content hashes avoid duplicate copies of identical bodies. There is no destructive retention task. Performance measurements from the earlier, smaller registry do not establish the expanded collector's memory or timing requirements.

PollingDesk's CSV has no explicit election-date or test-data columns. Its adapter is pinned to the inspected 2026 general-election catalog, validates the cycle/race/candidate scaffold and CivicAPI attribution, and exposes aggregate raw totals only. Keep it below the directly verified official and full-race sources. Recheck the catalog context if its publisher changes the feed; archive provenance instead of treating retrieval time as election-date proof. Matching CivicAPI and PollingDesk totals do not constitute two-source verification.

## Direct conditioning gates

The county scaffold must match the registry's expected statewide jurisdiction count, and each Senate race must contain that entire county set. A lone county source cannot stand in for a statewide Senate race. Senate historical matching uses 2024 presidential counties. House races require both independently verified unchanged district lines and an exact match to the historical district's county manifest. Counting one current House contest in a county does not prove that county is unsplit: another contest could simply be omitted. Missing, changed or unverified district geography therefore withholds direct conditioning. Every component must have a usable historical baseline.

Historical unopposed House portions are excluded as poor partisan baselines. A two-party matchup must have at least 5,000 counted two-party votes, at least 50% represented historical geography and at least 15% of assumed turnout before its returns create a measurement. Assumed total two-party turnout is 75% of the matching 2024 vote. These thresholds are conservative operating assumptions, not estimated reporting-completion facts.

There is a substantial uncertainty term for within-county reporting order, turnout and early/mail composition. The joint model also includes an observation-only state reporting-bias factor, so many races sharing an early batch cannot average that bias away. See `docs/election-night-model.md` for equations and limits.

Ranked-choice and independent matchups do not receive direct updates in this version. Alaska's PDF contains first-choice counts, not transfers or final ranked-choice outcomes. Aggregate-only sources and isolated official counties do not supply missing statewide geography. CivicAPI county reconciliation likewise does not replace an independent race manifest or matched historical baseline. In particular, a zero-valued county subset also sums to a zero contest total and is not accepted as proof of complete county coverage. These sources can display raw counts while races retain prior uncertainty or respond to shared evidence from other races. Changed districts without matching history remain outside direct conditioning. Expanded raw coverage leaves all of these model gates unchanged.

## Verification and audits

Dated source audits under `docs/research/` distinguish inspected official files, county portions, secondary aggregates, zero scaffolds, `NR`, test payloads and inaccessible routes. They record URLs, election identity, hashes and local samples. A registered URL, successfully parsed body, available raw race total, complete historical manifest and actual direct measurement are separate milestones; report their counts separately after running the final registry.

The final [coverage CSV](research/election-night-coverage-2026-11-03.csv) contains all 470 races, including at-large aliases, selected scope/source, baseline availability and separate available county detail. The [coverage audit](research/election-night-coverage-audit-2026-11-03.json) binds it to the final snapshot, frozen watchlist, source registry and immutable archive hashes. It contains source provenance and validation results, without model probabilities.

The first expanded network sweep took **102.23 seconds** with **607.39 MiB** maximum resident memory. The final refresh took **45.96 seconds** with **440.45 MiB**, using existing historical caches and some source reuse within request intervals; it is not a cold benchmark. An independent archived-input replay reparsed all **82 usable sources** and reproduced normalization and coverage in **11.61 seconds**, without network requests. The sandbox prevented that timing utility from reading replay memory, so no replay RSS figure is claimed. These measurements describe the development machine, not production capacity.

Final validation passed **1,550 tests and 6,474 assertions**, Rails autoload checks, and lint for 48 election-night Ruby files. Desktop and 375-pixel mobile browser checks found no horizontal overflow and verified the source accordion. The replay also reproduced the model output, but this checks determinism rather than historical calibration or live-election accuracy.

The earlier `docs/research/election-night-integration-check-2026-11-03.json` records an explicitly synthetic Republican-overperformance scenario and its stale development prior. It verifies response direction, not live returns or historical calibration. Earlier source counts, test totals and memory benchmarks describe that narrower implementation and must not be presented as validation of the expanded registry.

Tests cover election metadata, version binding, test rejection, missing values, vote-method reconciliation, duplicate candidates, fusion lines, county/summary double counting, last-good evidence, redistricting exclusions, deterministic inference, shared uncertainty, independent caucuses and UI refresh behavior. After registry integration, run the election-night tests, required application checks, Rails autoload validation and a cold archived-input sweep. Benchmark live-network duration separately from local parsing and inference. Browser demonstrations must remain clearly labeled and isolated from the collector's real snapshot.

## Before public operation

Capture a fresh, complete pre-election prior; verify nominees, uncommitted caucuses and election IDs; run the full collector from the intended hosting network; provision shared persistent storage and adequate memory/disk; inspect source scope, upstream attribution and timestamps; and verify the first nonzero batches against the linked official pages where available. For sources sharing CivicAPI, use independent evidence for cross-checks rather than counting two delivery paths twice. These are operational requirements, not deployment actions completed by this branch.

The largest product limitations are uneven direct official access, shared secondary upstreams, incomplete historical model coverage, county-level rather than ballot-method-conditioned inference, uncertain turnout, and no historical night-by-night calibration. Broad raw-result availability does not remove those limits. A working needle must not be described as equivalent to a mature national election-night forecasting operation.
