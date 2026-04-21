# Session Handoff — 2026-04-21

**Purpose:** complete record of the Claude Code session that bootstrapped this
repository, so the next agent (likely in a different environment) can continue
without rediscovering context.

**Branch:** `claude/explore-repo-contents-F0td7`
**Commits on branch:** see `git log`

---

## What this repo is

GitHub mirror of the **MIH Consolidated Knowledge Package** (Modelling Invasive
Mosquitoes in Hawaiʻi). The original source of truth is the Google Drive
project folder (`~/MIH/` on the project owner's local workstation). This repo
is the code + docs half; data stays on Drive.

See `README.md` for the project overview and `docs/PIPELINE_SPEC.md` for the
scientific argument and pipeline design. Read order for a new analyst /
agent: **PIPELINE_SPEC → STATUS → PROVENANCE → bibliography**.

---

## What happened in this session

### 1. Bootstrapped the repo from the MIH handoff zip

The user uploaded `019db253-MIH_consolidated.zip` (a 162 KB portable
handoff bundle prepared from the Drive project). It contained:

- `README.md` — project overview
- `docs/` — 4 living-doc markdown files (PIPELINE_SPEC, STATUS, PROVENANCE,
  MIH_bibliography)
- `scripts/` — 11 R files: steps 00–03 of an 8-step pipeline, plus
  `_pipeline_boilerplate.R`

The contents of that bundle were copied to the repo root and committed as
the initial commit (root commit `4b34f69` on
`claude/explore-repo-contents-F0td7`).

**Not in the bundle, still to import later:** scripts for steps 04 (area
stats + Venn), 05 (niche overlap, ecospat), 06 (ZINB survey model), 07
(manuscript figures), 08 (future projections). Per STATUS.md, step 03 is
tested and steps 04/05/07 are sequentially blocked by step 01 decisions.

### 2. Added a `.gitignore`

Excludes `data/`, `outputs/`, `results/`, `figures/`, `bibliography/`, PDFs,
and typical R junk — per the README, data lives on Drive and is never
committed.

### 3. Investigated Google Drive access

User provided two Drive folder URLs and asked about auth vs public sharing.
Findings below.

### 4. Registered Drive folders in `docs/DATA_SOURCES.md`

Two canonical Drive folders (contents not yet described by project owner —
**fill these in next session**):

1. `https://drive.google.com/drive/folders/1xWKnA21WoAZIIiMJZXBE0dBE3JeQZ83Z`
2. `https://drive.google.com/drive/folders/1KcBDyNGQhB0nE_xyhEGHtF2DddOVtfkh`

### 5. Probed the sandbox environment

Key findings — see "Environment constraints" below.

---

## Environment constraints (this sandbox)

Running in Anthropic's managed Claude Code web sandbox. Tested 2026-04-21:

### Network (TLS-intercepting egress proxy)

Proxy CA: `O=Anthropic; CN=sandbox-egress-production TLS Inspection CA`.
Denies return `x-deny-reason: host_not_allowed`.

| Host | Status |
|---|---|
| `github.com` | ✅ 200 |
| `pypi.org` | ✅ 200 |
| `www.googleapis.com` | ✅ reachable (returns Google's own 404 at `/`) |
| `drive.google.com` | ❌ 403 blocked |
| `google.com` | ❌ 403 blocked |
| `cran.r-project.org` | ❌ 403 blocked |

### Toolchain

- **R / Rscript:** not installed. `r-base 4.3.3` is in apt but has not been
  installed. Even if installed, CRAN is blocked so `install.packages()`
  would fail. Pipeline R deps (`terra`, `ncdf4`, `ENMeval`, `ecospat`,
  `here`, `conflicted`) are therefore not attainable here.
- **Python / pip:** PyPI reachable, so `pip install gdown` would succeed —
  but `gdown` targets `drive.google.com`, which is blocked, so `gdown` is
  effectively useless from this sandbox.

### Disk

- `/`: 252 GB total, 31 GB free at session start.
- Repo itself: 580 KB.
- Plenty for code/docs, tight for full Hawaii raster stacks at 250 m.

### Implication

**This sandbox is a code/docs editor only**, not a pipeline runner. Anything
involving running R, installing packages, or fetching Drive data must happen
on a local workstation or in an environment with open egress and R
installed.

---

## Recommended next environment

For pipeline work, run Claude Code locally on the project owner's workstation
(where `~/MIH/` already has the data, R is installed, and Drive is reachable):

```bash
npm install -g @anthropic-ai/claude-code
cd ~/MIH    # or wherever the working copy of this repo lives
claude
```

That environment can actually run the scripts in `scripts/`, pull from
Drive with `gdown`, and install R packages as needed.

Use this managed sandbox only for isolated code-only tasks (refactors,
drafting new scripts from spec, doc work, bibliography maintenance).

---

## Open items for next session

1. **Describe the two Drive folders** in `docs/DATA_SOURCES.md` — what's in
   each, and what local `data/` subdirectory they should land in.
2. **Write `scripts/fetch_data.sh`** once (1) is known — a thin `gdown
   --folder` wrapper that mirrors Drive → `data/`.
3. **Decide whether to draft `CLAUDE.md`** at the repo root so future Claude
   sessions automatically pick up the "read PIPELINE_SPEC first, then
   STATUS" onboarding. Currently not present.
4. **Import scripts 04–08** when they're ready in the source `~/MIH/scripts/`
   directory. Update the "What's in the bundle" section of `README.md`
   accordingly.
5. **Resolve open pipeline decisions** listed in `STATUS.md` (variable set
   choice, thinning distance, Step 03 ENMeval grid) before proceeding to
   steps 04–05.

---

## Repo state at handoff

- Branch `claude/explore-repo-contents-F0td7` created, pushed, tracked
  against origin.
- Remote: `http://local_proxy@127.0.0.1:41331/git/jwinchester/MosquiTrap-Analysis`
  (this sandbox's proxied git remote — the real GitHub repo is
  `jwinchester/mosquitrap-analysis`).
- No PR opened (user has not requested one).
- Tree clean at time of writing; this handoff doc + `DATA_SOURCES.md` +
  the STATUS update will be in a separate follow-up commit.
