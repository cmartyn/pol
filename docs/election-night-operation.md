# Operating the independent election-night prototype

This feature is isolated on `codex/election-night-needle`. It does not write existing forecasts, trigger newsroom stories or send email. Collection is disabled by default. Nothing has been deployed.

## What exists

`/election-night` is a public page with separate House and Senate probability gauges, expected Democratic-caucus seats, direct versus shared race updates, raw vote coverage, source health, timestamps and assumptions. It refreshes every 30 seconds and keeps the last display if the connection fails. `/election-night/snapshot` returns the versioned snapshot with no-store caching.

The collector consumes raw official returns for NC, AZ, GA, VA, TX, FL and Kent County, Michigan, plus Iowa Ledger's attributed raw totals. Ohio is configured but rejects the current explicitly marked test payload. Florida's direct text download works even though its website blocked the probe; its historical baseline also comes directly from the state. The registry and source documentation are in `config/election_night_sources.yml` and `docs/election-night-sources.md`.

No provider probabilities, expected-vote estimates or race calls are imported. Our own frozen polling prior, historical vote counts, explicitly stated turnout assumptions and the joint inference model determine the probabilities. The model is experimental, not historically calibrated.

## Local operation

Use the repository's Ruby version and installed bundle. From this checkout:

```sh
bin/rails election_night:freeze
bin/rails election_night:sweep
bin/rails server
```

Visit `/election-night`. Freeze reads the latest completed pre-election forecast and requires 435 House plus 35 Senate races. A prior is frozen only once per storage directory. Freeze should be performed with the final intended pre-election polling run, after checking candidate/caucus mappings and current district baselines.

**The local development database used for verification only has an October 21 prior.** That timestamp is retained and shown on the page. It is suitable for an integration check, not a November 3 launch prior. Do not publish the local verification snapshot as a current election-day forecast.

For a separate experiment, set an absolute `ELECTION_NIGHT_STORAGE` path consistently for freeze, sweep, web and worker. The default is the ignored `storage/election_night` directory. Do not replace an existing prior in place; use a new directory and retain the old experiment for audit.

For recurring operation after deployment review, set `ELECTION_NIGHT_ENABLED=true` on the worker and restart it. This enables a GoodJob sweep every three minutes. Leave it unset to keep the feature manual. The existing polling-model and newsroom schedules are unchanged. Ensure the worker processes the `election_night` queue.

## Storage and concurrency

- One process holds an OS file lock for an entire collection/inference/publication pass. A competing invocation exits instead of overlapping.
- Raw response bodies are stored by SHA-256, with source/election metadata and original timestamps. Corrected totals replace the current normalized snapshot; earlier raw versions remain available.
- Historical baseline bodies and hashes are frozen in the source record. NC ZIP decoding uses `unzip`, now included in the Docker image.
- Normalized source records carry a parser version. Changing normalization invalidates cached results and baselines; raw archives stay intact. This prevents pre-fix county names or validation rules from silently surviving a code update.
- `latest.json` is published by atomic rename after a complete model calculation. Each model snapshot is also retained in `history/` with input hashes and the measurements used.
- The web and worker must mount the **same persistent filesystem directory**. This implementation is not a multi-host object-store publisher. Do not assume unrelated container filesystems share snapshots.
- Failed source requests retain previously validated data with its original retrieval timestamp and an explicit error/stale status. A transient outage does not erase counted votes. A model using such a source is labeled stale. Failed inference leaves the previous public snapshot untouched.
- Fetch time and publication time are separate. A successful fetch can return an unchanged report. Zeroed pre-poll scaffolds are not treated as evidence. Monitor long-unmoved reports during counting; the collector cannot prove that officials have finished counting.
- Some raw exports are tens of megabytes; provision disk for archived revisions, and use a dedicated collector resource budget rather than assuming the existing small host has ample headroom. The Enhanced Voting parser discards unused precinct/method subtrees while validating the whole document, preserving exact county totals and the raw archive. Content hashes avoid duplicate copies of identical bodies. There is no destructive retention task.

## Direct conditioning gates

The county scaffold must match the registry's expected statewide jurisdiction count, and each Senate race must contain that entire county set. A lone county source cannot stand in for a statewide Senate race. Senate historical matching uses 2024 presidential counties. House races require both independently verified unchanged district lines and an exact match to the historical district's county manifest. Counting one current House contest in a county does not prove that county is unsplit: another contest could simply be omitted. Missing, changed or unverified district geography therefore withholds direct conditioning. Every component must have a usable historical baseline.

Historical unopposed House portions are excluded as poor partisan baselines. A two-party matchup must have at least 5,000 counted two-party votes, at least 50% represented historical geography and at least 15% of assumed turnout before its returns create a measurement. Assumed total two-party turnout is 75% of the matching 2024 vote. These thresholds are conservative operating assumptions, not estimated reporting-completion facts.

There is a substantial uncertainty term for within-county reporting order, turnout and early/mail composition. The joint model also includes an observation-only state reporting-bias factor, so many races sharing an early batch cannot average that bias away. See `docs/election-night-model.md` for equations and limits.

Ranked-choice and independent matchups do not receive direct updates in this version. Nor do Iowa's aggregate-only totals or Kent alone supply missing statewide geography. They can display raw counts while those races retain prior uncertainty or respond to shared evidence from other races. Changed districts without a matching baseline remain explicitly outside direct conditioning. The prototype does not have complete competitive-race coverage.

## Validation performed

- Actual current source bodies were fetched and parsed before polls closed; all eight accepted sources contained zero votes at that point. Ohio's test payload was rejected. Historical county names, candidate-party totals and district portions were matched using the downloaded files.
- An archived-payload integration pass found 44 races with complete usable historical geography under the final strict race-manifest checks. This is a source/baseline count, not a claim that 44 races had reported votes.
- A separately labeled synthetic check injected Republican overperformance into those matched units. Both chamber probabilities fell. `docs/research/election-night-integration-check-2026-11-03.json` records that scenario and the stale local prior date. It is neither live election data nor a calibration replay.
- Tests cover wrong dates, test feeds, malformed counts, duplicates, source failures, county/summary double counting, geography bias, redistricting exclusions, last-good evidence, deterministic inference, correlated uncertainty, independent caucuses, UI states and refresh errors.
- The complete application suite passed 1,470 tests and 5,973 assertions. The final cache-version safeguard also passed its focused five-test collector suite. Rails autoload validation and all 27 inspected Ruby files passed.
- Desktop and mobile browser checks used clearly labeled synthetic demonstration data; no invented probabilities were written to the real collector's public snapshot.
- A cold archived-input run including all nine sources, historical decoding, a 10,000-draw control and a second 10,000-draw synthetic inference completed in 21.48 seconds locally at 431 MB peak RSS. Streaming North Carolina rows and pruning unused Enhanced Voting details reduced peak memory from roughly 1.47 GB. This is a local measurement, not a hosting guarantee; network fetch time is excluded.

## Before public operation

Capture a fresh, complete pre-election prior; verify nominees, uncommitted caucuses and election IDs; run the collector from the intended hosting network; provision a shared persistent storage mount and adequate memory/disk; inspect the raw/source/model timestamps; and verify the first nonzero batches against the linked source pages. These are remaining operational requirements, not actions completed by this branch.

The largest product limitations are incomplete source coverage, county-level rather than ballot-method-conditioned inference, uncertain turnout, and no historical night-by-night calibration. The page surfaces these limits. A working needle must not be described as equivalent to a mature national election-night forecasting operation.
