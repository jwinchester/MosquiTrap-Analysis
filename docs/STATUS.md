# MIH Status

**Purpose:** the churning state of the project. Open decisions, current blockers,
data acquisition, Drive sync, what-to-do-next. Updated after every working session.

**Last updated:** April 21, 2026

**Sister docs:** `PIPELINE_SPEC.md` (stable design), `PROVENANCE.md` (lineage
and email archaeology), `MIH_bibliography.md` (citations), `DATA_SOURCES.md`
(Drive folder registry), `SESSION_HANDOFF.md` (last-session log).

---

## At a glance

- **Step 00** (occurrence staging) — complete. 63 hist aeg / 168 mod aeg / 766 mod albo.
- **Step 01** (env layers) — all sub-steps 01a–01e complete under current spec.
- **Step 02** (occurrence cleaning) — complete, outputs present.
- **Step 03** (ENMeval & bootstrap MaxEnt) — script complete and tested.
- **Steps 04, 05, 07** — not started. Sequentially blocked by Step 01.
- **Step 06** (ZINB survey model) — can proceed independently.
- **Step 08** (future projections) — deferred; data received.

## Open decisions (from last status update)

See the full living doc for current state. Key blockers:

1. **Variable set / track** — Which env stack is authoritative? Decision impacts Steps 01–05.
2. **Thinning distance** — 1km vs 2km? Decision #4 resolution pending.
3. **Step 03 search grid** — ENMeval tuning parameters. Decision #13–#15 pending.

## Next actions

1. Acquire WorldClim v1.4 and v2.1 (scriptable).
2. Write and run `01_env_layers.R` (main).
3. Resolve open decisions before proceeding to Steps 04–05.

## Repo / environment (added 2026-04-21)

- Code and docs now mirrored to the `MosquiTrap-Analysis` GitHub repo on
  branch `claude/explore-repo-contents-F0td7`.
- Two canonical Drive folders registered in `DATA_SOURCES.md` (contents
  still to be described).
- Anthropic's managed Claude Code web sandbox **cannot reach
  `drive.google.com`** and **cannot install CRAN packages**. Pipeline work
  must happen locally. See `SESSION_HANDOFF.md` for full environment probe
  results and next-session checklist.

