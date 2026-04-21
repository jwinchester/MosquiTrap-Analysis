# MIH Provenance and Archaeology

**Purpose:** data lineage, email archaeology, and reconstruction of what the
original thesis / Karl analysis actually did. This is institutional memory —
the "why" behind data choices.

**Sister docs:** `PIPELINE_SPEC.md` (stable design contract), `STATUS.md`
(current state and open decisions), `MIH_bibliography.md` (citation records).

---

## How the original bioclim variables were derived

The manuscript states that bioclim variables were derived from Hawaii-specific
inputs:

- **Monthly rainfall:** Rainfall Atlas of Hawaiʻi month-year grids (Frazier
  et al. 2015/2016)
- **Monthly temperature:** 2014 Hawaii Climate Atlas

Critically, the temperature data was applied to both historic and contemporary
models — not period-specific.

---

## The temperature-data gap — and why the current pipeline is an upgrade

Historic temperature (1957–1966) was not available at the time of the original
analysis. The current pipeline addresses this with:

- Historic temperature: **WorldClim v1.4** (Hijmans et al. 2005), 1960–1990 baseline
  (3-year offset from intended 1957–1966; within validation noise floor)
- Historic rainfall: retained from original Frazier atlas approach

ERA5-Land was acquired and tested (April 2026) but retired after validation
revealed structural terrain bias over Hawaiian topography. WorldClim v1.4 is
the robust fallback for historic analyses.

---

## Key decisions and their rationale

### Decision #17 (April 2026): ERA5-Land retirement

**Finding:** ERA5-Land has systematic elevation-dependent bias over Hawaii's
steep terrain. GHCN-Daily validation showed ERA5-Land consistently
overestimates low-elevation temperatures and underestimates high-elevation
values relative to observed station data.

**Resolution:** Retire ERA5-Land from the historic temperature pipeline.
Use WorldClim v1.4 instead. Contemporary analyses retain flexibility to use
HCDP downscaled ERA5 (decision #1 still open).

**Impact:** Historic and contemporary pipelines now aligned on a single
World Clim baseline—simplifies methods section and interpretation.

---

## Google Drive folder structure — canonical form

Drive mirrors local `~/MIH/` path-for-path under `MIH_Mosquitoes_Hawaii/`.
Forward-slash paths throughout. The old Drive structure used underscore aliases
(`data_field`, `data_public`) — these were renamed to `data/field` and
`data/public` in April 2026. Any audit or push script must use the slash form.

