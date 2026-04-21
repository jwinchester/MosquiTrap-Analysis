# MIH Data Sources

**Purpose:** authoritative registry of where raw and derived data files live.
Per the project README, data is **not** committed to this repo — it is stored
in Google Drive and mirrored to local `data/` on each analyst's machine.

**Last updated:** April 21, 2026

---

## Google Drive folders

These are the canonical Drive folders for this project. Set to link-viewable
sharing so any collaborator (and `gdown --folder`) can fetch them on a
machine with outbound Drive access.

| # | URL | Contents (TBD — pending description from project owner) |
|---|---|---|
| 1 | https://drive.google.com/drive/folders/1xWKnA21WoAZIIiMJZXBE0dBE3JeQZ83Z | *describe what's in this folder* |
| 2 | https://drive.google.com/drive/folders/1KcBDyNGQhB0nE_xyhEGHtF2DddOVtfkh | *describe what's in this folder* |

> **TODO (next session):** fill in what each folder holds (e.g., raw
> occurrences, HCDP rasters, WorldClim stacks, field trap data) so the fetch
> script below can map them into the correct `data/` subdirectories.

---

## Fetching data on a local machine

The pipeline scripts expect data under `data/` using the layout described in
`PIPELINE_SPEC.md`. To populate it from Drive:

```bash
# one-time
pip install --user gdown

# pulls folder contents into ./data/<folder_name>/
gdown --folder "https://drive.google.com/drive/folders/1xWKnA21WoAZIIiMJZXBE0dBE3JeQZ83Z" -O data/
gdown --folder "https://drive.google.com/drive/folders/1KcBDyNGQhB0nE_xyhEGHtF2DddOVtfkh" -O data/
```

A wrapper script will live at `scripts/fetch_data.sh` once folder contents
are documented and we know the expected target paths.

---

## Sandbox access note

The **Anthropic-managed Claude Code web sandbox** used in some sessions has
an egress allowlist that **blocks `drive.google.com`** (HTTP 403,
`x-deny-reason: host_not_allowed`). `www.googleapis.com` is reachable, so a
service-account approach against the Drive REST API would work if needed,
but is not currently set up.

For pipeline work that actually touches data, run Claude Code locally on a
workstation where the Drive share is accessible and R / system libraries are
installed. See `SESSION_HANDOFF.md` for full environment details.
