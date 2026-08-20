# PostHog Self-driving Setup Report

## Summary

PostHog Self-driving has been configured for **535** (the 2026 U.S. midterms forecasting site). Session Replay, Error Tracking, and Support products were enabled; six native signal sources were wired to the inbox; GitHub was connected; four scouts were tuned (general + three specialists); and two Replay Vision scanners were created to watch dispatch article pages and rage-click sessions. Findings will start appearing in the [Self-driving inbox](https://us.posthog.com/project/566737/inbox) within approximately 30 minutes.

---

## AI data processing

**Approved.** Organization-level AI data processing consent was granted before this run started.

---

## GitHub

**Connected during this run.** GitHub App installed by Chase Martyn (cmartyn) — integration id `234139`, connected at 2026-08-20T01:26:31Z. One repository is connected; the connected repo will be used for code research and draft PRs.

---

## Products enabled

| Product | Status | Notes |
|---|---|---|
| Session Replay | **Follow-up required** | `products-enable` tool not available on this deploy. Enable manually: PostHog → Settings → Session replay → "Record user sessions". The posthog-js `init` has no `disable_session_recording` override — once the product is ON, recordings flow immediately. |
| Error Tracking | **Follow-up required** | Same as above. Enable via Settings → Error tracking → "Enable exception autocapture". `posthog-rails` is already configured with `auto_capture_exceptions: true` and `report_rescued_exceptions: true` — backend exceptions will flow as soon as the product toggle is on. |
| Support (Conversations) | **Follow-up required** | Enable via the Support section in the PostHog product sidebar. Tickets only arrive once an inbound channel (email, inbox, or Slack) is connected — see Follow-ups. |

> **Note:** Signal sources for all three products were wired up regardless (step 4). The sources sit idle until the product toggles are enabled, then pick up data with no second setup.

---

## Signal sources

| source_product | source_type | Action | Config id |
|---|---|---|---|
| `signals_scout` | `cross_source_issue` | **ON by default** — no row needed; scout findings reach the inbox automatically | — |
| `health_checks` | `health_issue` | **Enabled** (created) | `01a01cc8-5e2c-7cc9-9e89-bad28c656f1e` |
| `error_tracking` | `issue_created` | **Enabled** (created) | `01a01cc8-63b3-7059-b7d9-56b5b18afd65` |
| `error_tracking` | `issue_reopened` | **Enabled** (created) | `01a01cc8-667d-70e4-ab85-f006116c0261` |
| `error_tracking` | `issue_spiking` | **Enabled** (created) | `01a01cc8-6be0-7212-aa78-dd18945da349` |
| `session_replay` | `session_analysis_cluster` | **Enabled** (created, server default sample rate 10%) | `01a01cc8-6f33-74c0-879f-59a186fb2ed1` |
| `conversations` | `ticket` | **Enabled** (created) — dormant until an inbound channel is connected | `01a01cc8-71d6-7f3b-abb6-890ea01facec` |
| `llm_analytics` | — | **Skipped** — internal only, not a user-facing responder |
| `logs` | — | **Skipped** — not a v1 responder |
| `replay_vision` | — | **Skipped** — Replay Vision scanners self-authorize via `emits_signals`; no row needed |

---

## Connected tools

No external tools were selected. All connected-tool sources were skipped (not used).

---

## Scout troop

**4 active, 23 disabled.** Run budget: 100 runs/day (early access default); 0 used today.

> *Banner from PostHog:* "Scouts are in early access. Each project gets up to 100 scout runs a day. Contact team-self-driving@posthog.com if you need more."

### Enabled

| Scout | Why |
|---|---|
| `signals-scout-general` | Always on — cross-product correlations and surfaces no specialist covers |
| `signals-scout-product-analytics` | 535 captures custom conversion events (`subscriber_signed_up`) and funnel-relevant events (`dispatch_viewed`, `race_viewed`); this scout watches saved funnel/retention insights for regressions |
| `signals-scout-web-analytics` | 535 is a multi-page content site; per-channel traffic, attribution breakage, and landing-page health are core metrics |
| `signals-scout-observability-gaps` | Fresh PostHog setup; flags event volumes (e.g. `email_send_failed`, `subscriber_unsubscribed`) that lack insight/dashboard/alert coverage |

### Disabled

| Scout | Reason |
|---|---|
| `signals-scout-error-tracking` | **Covered by native source** — error_tracking source (issue_created/reopened/spiking) already routes error findings to the inbox |
| `signals-scout-session-replay` | **Covered by native source** — session_replay source (session_analysis_cluster) already routes session findings to the inbox |
| `signals-scout-ai-observability` | No `$ai_*` events captured; `ruby_llm` is used for generation but without LLM analytics instrumentation. Enable if you add `$ai_*` tracking. |
| `signals-scout-feature-flags` | No feature flags in use. Enable if you add flags. |
| `signals-scout-surveys` | No surveys in use (0 surveys found). Enable if you add surveys. |
| `signals-scout-revenue-analytics` | No payment SDK or revenue data. 535's subscriptions are email-only, not paid. |
| `signals-scout-experiments` | No A/B experiments running. Enable when you run experiments. |
| `signals-scout-csp-violations` | No Content Security Policy reporting configured. |
| `signals-scout-customer-analytics` | No groups/accounts analytics in use. |
| `signals-scout-data-pipelines` | No CDP destinations, batch exports, or hog flows configured. |
| `signals-scout-logs` | PostHog logs product not in use. |
| `signals-scout-replay-vision` | Reads trends *across* accumulated scanner observations; new scanners from this run have no history yet. Enable after recordings accumulate. |
| `signals-scout-apm` | No OpenTelemetry/distributed tracing configured. |
| `signals-scout-conversations` | No support tickets yet; conversations product needs a channel connected first. |
| `signals-scout-anomaly-detection` | No saved dashboards/insights with baseline history yet. Enable once insights are built. |
| `signals-scout-data-warehouse` | No warehouse sources connected. |
| `signals-scout-inbox-validation` | Fresh setup — no shipped fixes to validate yet. Enable after the team has resolved several inbox reports. |
| `signals-scout-insight-alerts` | No insight alerts configured yet. |
| `signals-scout-mcp-tool-calls` | Not applicable for this product. |
| `signals-scout-skills-store` | Not a priority surface for this project. |
| `signals-scout-tasks` | Not a priority surface for this project. |
| `signals-scout-web-vitals` | No `$web_vitals` events confirmed. Enable if you add Web Vitals capture to the frontend. |

---

## Custom scouts

**None — declined.** Two candidates were proposed and the user chose to keep the built-in troop as-is.

**Proposed (declined):**
- *Watch email delivery pipeline for failure spikes* — would have watched `email_send_failed` events for rate spikes relative to dispatch volume. Surface: dispatch email delivery via Resend. Discriminator: `email_send_failed` rate vs. delivery attempts in a rolling window. Not covered by error tracking (which catches Ruby exceptions, not business-logic delivery failures) or web analytics. Ruled out: user declined.
- *Watch subscriber churn balance for net-negative flows* — would have watched `subscriber_signed_up` vs. `subscriber_unsubscribed` balance for net-negative or spike patterns. Discriminator: 7-day rolling unsubscribe rate > 2× 30-day baseline. Not covered by product-analytics (which requires saved funnel insights that don't yet exist). Ruled out: user declined.

**Noise escape hatch:** if any built-in scout turns out noisy, set `emit: false` on its config in PostHog to switch it to dry-run — it will keep running and logging without writing to the inbox.

---

## Replay Vision scanners

A Replay Vision scanner is an LLM that watches individual session recordings on a schedule and pushes what it finds to the inbox when `emits_signals` is true. Findings arrive at half weight; a report is promoted when it reaches full weight, so a single finding needs corroboration before it becomes an inbox report. The scanners below are the only part of this setup that spends Replay Vision quota.

**The project has no recordings yet.** Both scanners are armed and will start working automatically the day recordings begin — no second setup needed.

Credit spend was not formally verified (the `creating-replay-vision-scanners` sizing skill returned 404 on this deploy). Both scanners are deliberately narrow (scoped query + low sampling rate), so their projected spend is near zero on a project with no recordings; note the actual spend when recordings begin and adjust `sampling_rate` or add a `credit_limit` if needed.

### Scanner 1 — Broken experiences

| Field | Value |
|---|---|
| id | `01a01cce-77b5-7d38-beb0-57926f6ff9af` |
| Status | **Created**, enabled, `emits_signals: true` |
| Watches | Sessions that visited a `/dispatches` URL |
| Why this flow | Dispatch article pages are where users engage most deeply with 535's forecasts and are most likely to subscribe — a silent breakage here (blank screen, broken layout, failed content load) directly costs subscriber conversion |
| sampling_rate | 0.5 (50% of matching sessions) |
| Model | gemini-3.7-flash (15 credits/observation) |
| Estimated monthly spend | 0 credits (no recordings yet) |

### Scanner 2 — User frustration

| Field | Value |
|---|---|
| id | `01a01cce-891f-73b1-8315-924634ab76a6` |
| Status | **Created**, enabled, `emits_signals: true` |
| Watches | Sessions containing a `$rageclick` event (any page) |
| Why this gate | Rage-clicks are the friction itself, not a proxy — narrow gate, affordable at 100% sampling; deliberately has no URL scope to avoid overlapping with scanner 1 |
| sampling_rate | 1.0 (all rage-click sessions) |
| Model | gemini-3.7-flash (15 credits/observation) |
| Estimated monthly spend | 0 credits (no recordings yet) |

---

## Follow-ups

- [ ] **Enable Session Replay** — PostHog → Settings → Session replay → "Record user sessions". No code change needed; the posthog-js init is already clean.
- [ ] **Enable Error Tracking** — PostHog → Settings → Error tracking → "Enable exception autocapture". The Rails backend is already configured to capture exceptions.
- [ ] **Enable Support (Conversations)** — PostHog product sidebar → Support. Then connect an inbound channel (email, inbox, or Slack) so tickets can actually arrive. The `conversations/ticket` signal source is already wired — tickets will reach the inbox automatically once a channel exists.
- [ ] **Enable feature-flags scout** — if you start using PostHog feature flags, enable `signals-scout-feature-flags` in the inbox.
- [ ] **Enable surveys scout** — if you add PostHog surveys, enable `signals-scout-surveys`.
- [ ] **Add LLM analytics tracking** — if you want to monitor `ruby_llm` generation quality/cost, instrument `$ai_*` events and enable `signals-scout-ai-observability`.
- [ ] **Enable replay-vision scout** — after recordings have accumulated and the Replay Vision scanners have run for a few weeks, enable `signals-scout-replay-vision` to catch scanner throughput cliffs and observation trends.
- [ ] **Set scanner credit limits** — once recordings begin, check actual credit spend in the Replay Vision UI and optionally set `credit_limit` on each scanner via `vision-scanners-update` to cap monthly spend.
- [ ] **Review custom scout proposals** — two scouts were proposed and declined: an email delivery failure spike watcher and a subscriber churn balance watcher. Re-run this setup or author them manually if you change your mind.

---

## What happens next

The scout coordinator picks up fresh configs within ~30 minutes; each enabled scout draws one run from the project's daily budget (100 runs/day during early access). Scout findings cluster into reports; immediately actionable ones can start coding tasks. Replay Vision scanners sweep matching recordings every 5 minutes once recordings exist. Check your [Self-driving inbox](https://us.posthog.com/project/566737/inbox) for the first findings — they typically appear within 30 minutes of the coordinator's first tick.
