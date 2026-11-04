# Northeast adapter fixture provenance

Retrieved November 3, 2026 before polls closed. These are schema-validation samples, not evidence of live update reliability. Tests that insert positive vote counts are synthetic unit tests.

- `rockland_summary.json`: reduced official Rockland GE2026 export, retaining the congressional contest and all fusion ballot lines; precinct details and unrelated contests removed. Original URL, SHA-256 and sample path are in `docs/research/election-night-northeast-audit-2026-11-03.json`.
- `atlantic_summary.json` and `atlantic_metadata.json`: federal contests and required metadata fields extracted from official Clarity version 381767. No vote values changed.
- `maryland_house.html`: main result section extracted from the official all-House-district page, with trailing line whitespace removed. All totals were `NR` (not reported). District 8's source table has no Totals row; the parser permits that and sums numeric candidate rows only when present.
- Civic files below are unmodified full-race responses. The Senate fixture deliberately contains overlapping geographic levels, including Borough and House District. The adapter selects one county-equivalent level, retains all candidates, and ignores winner/percent/other presentation fields. No provider forecast is used.

Civic full sample hashes:

- `civic_al_house.json`: 633df27e41ba84a661fedce643fcc4c42e4d0ab3aebabe57961c69b401940634; https://civicapi.org/api/v2/race/86901
- `civic_ak_senate.json`: 2fff9a859724988620ea9870e53fe6fd63c0d177b36035e1f89304c38adbb191; https://civicapi.org/api/v2/race/86916
