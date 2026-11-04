# Validating the CivicAPI primary feed

The pinned `config/election_night_civic_races.json` catalog identifies all 435 House and 35 Senate races for November 3, 2026. It includes each exact full-race endpoint and the hashes of the two national discovery responses. National summaries discover endpoint IDs; candidate counts are accepted only after the full-race response passes the CivicAPI adapter.

`ElectionNight::CivicCatalog` verifies the exact House delegation, the 35 expected Senate states, unique endpoint IDs, at-large district names and approved HTTPS URLs. Its `sources(minimum_interval:, priority:)` interface supplies the collector's per-race configuration. Catalog completeness does not prove that every endpoint is currently available or has complete county geography.

The standalone audit script uses the repository's Ruby version and does not need a database or Rails server:

```sh
ruby script/validate_election_night_civic.rb \
  --store /absolute/path/to/isolated-civic-audit \
  --reuse-store /absolute/path/to/earlier-audit
```

Omit `--reuse-store` for a new network audit. A previously used destination is resumable: successful stored bodies are hashed and reparsed, and only missing or failed sources are fetched again. Use a new destination when a fresh network audit is required. Reused records retain their original `fetched_at`; reparsing does not make the publisher's report newly retrieved.

The script makes one request at a time, with a minimum delay of 0.25 seconds. Transient HTTP failures and network exceptions receive at most three retries with increasing delays. A permanent HTTP failure such as 403 is recorded without retrying or bypassing access controls. TLS certificate verification stays enabled. Response bodies have a size limit. The script exits unsuccessfully if any race remains unvalidated.

The isolated output contains:

- `raw/<source-id>/<sha256>`: immutable response bodies, including unsuccessful HTTP responses when received.
- `sources/<source-id>.json`: accepted normalized counts or an explicit unavailable/error record, compatible with the collector's current normalization version.
- `validation/<source-id>.json`: HTTP attempt status, timestamp, response hash and retry errors.
- `civic_validation.json`: timing, coverage totals and per-source validation results. Failed races have no vote total; missing data is never represented as a reported zero.

Resume checks the archive checksum and reparses the body instead of trusting cached normalized results. A corrupted existing archive fails validation rather than silently overwriting history. The final report contains raw counts and provenance, without provider forecasts, winner calls or modeled remaining vote.

Every response must match the expected state, office, district, general-election date and explicit non-test flag. County candidate rosters and candidate-level sums must reconcile to the full contest before county detail is retained. Accepted zero-valued county rows do not independently establish a complete race manifest: a subset can also sum to zero. Historical geography, candidate/caucus mapping, sufficient counted votes and all other direct-model gates remain separate requirements.

This script audits source responses; the production collector controls polling and publication. A successful pre-poll audit cannot establish later counting speed, reliability or completeness. CivicAPI and PollingDesk share an upstream and must not be counted as independent corroboration.

## Source freshness and geographic ambiguity

The collector's healthy/error/stale status describes retrieval health. A successful HTTP response can repeatedly return an old CivicAPI report. The resolver prefers the healthy primary; its existing failure/stale fallback does not automatically detect that an official source has newer counts. An official source can therefore contain positive returns while the selected primary still contains an older zero scaffold.

No automatic timestamp override is enabled without verified, comparable count-update semantics. Enhanced Voting's `createdAt` and Indiana's `WriteTime` describe published exports; Arkansas's `lastUpdated` is read from companion election metadata. Other official sources lack a trustworthy UTC publication time. These fields do not establish when each race's count batch changed, and later retrieval or export generation cannot prove that a conflicting count is newer. Comparing raw totals alone is also unsafe because legitimate corrections can decrease votes. This remains an operational limitation requiring source review; report retrieval health separately from counting progress.

If two rows in one source normalize to the same county for the same race, the resolver withholds that source's entire race geography. Keeping the first row could undercount disjoint portions, while summing could double-count a repeated report. A separately validated contest aggregate remains available, and direct evidence can use a complete, unambiguous snapshot from another publisher. `county_rejections` records the affected source, race, canonical county and original row names. Rows from different publishers still follow source priority; they are not added together as independent votes.

## November 3 full-board audit

The [full validation audit](research/election-night-civic-full-validation-2026-11-03.json) records **470/470 successful full-race responses**: 410 new sequential requests and 60 reparsed earlier archives. The network audit took 505.68 seconds, with no HTTP failures or retries. All accepted counts were zero.

The completed validation found county detail in **466 races**, totaling **6,159 county-equivalent rows**; 5,998 rows supplied FIPS codes. Mississippi's four House responses contain only a state summary, so those remain contest-only. Available detail does not establish complete geography or a usable historical match.

The audit also exposed a parser omission: Virginia labels its independent cities `City`. A Virginia-only allowlist, checked against all 38 independent cities in the official state export, now retains those county equivalents. It excludes ordinary municipalities and preserves Charles City and James City as counties. The normalization version is 3. A final archive-only pass reparsed all 470 responses with that version in 0.393 seconds, with every raw checksum verified and no network requests. All records retain their original fetch timestamps and carry the primary-source role and priority.
