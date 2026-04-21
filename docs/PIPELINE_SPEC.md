# MIH Pipeline Specification

**Project:** Modelling Invasive Mosquitoes in Hawaiʻi
**Lead:** Jon Winchester
**This doc:** the stable design contract — conventions, directory structure, per-step
I/O, dependency graph. Changes rarely.

**Sister docs** (all live in the Claude project):
- `STATUS.md` — current state, open decisions, blockers, what-to-do-next
- `PROVENANCE.md` — data lineage, email archaeology, original-analysis reconstruction
- `MIH_bibliography.md` — citation records and PDF acquisition status

**External docs:**
- MIH Analysis Plan (Google Doc, shared with collaborators) — the public-facing,
  lighter-touch version of this spec
- Manuscript (Google Doc) — the guiding document that defines scientific objectives

---

## Scientific argument (guiding principle)

*Ae. albopictus* competitively excludes *Ae. aegypti* wherever it can establish.
*Ae. aegypti* persists only in hot/dry leeward coastal refugia where high vapour
pressure deficit (VPD) suppresses *albopictus* egg survival — an **abiotic refuge
from competitive exclusion**, not a preferred niche. All analytical choices are
evaluated against how well they illuminate or test this argument.

---

## Design conventions

### Three-tier file resolution

Every script uses a `resolve()` function that tries three tiers in order:

1. **Local:** file exists at expected path and passes optional validation → use it
2. **Drive:** not local (or local failed validation) → download from Google Drive
3. **Public source:** not on Drive → re-fetch from original URL (only valid for
   `data/public/` files, never field data or outputs)
4. **Fail loudly:** none of the above → `stop()` with a clear message naming the
   missing file and which upstream step should have produced it

`local_path` is interpreted as **relative to the project root** (the directory
containing the `.here` sentinel, typically `~/MIH/`). `resolve()`'s first line
runs `here::here(local_path)` to resolve it against the sentinel, making call
sites work identically whether the script is invoked via RStudio's MIH.Rproj,
`Rscript` from any directory, or sourced from the R console. Absolute paths
pass through unchanged.

`fetch_fn` is optional. Some `data/public/` sources cannot be scripted — HCDP
portal orders, Copernicus CDS orders, and anything else acquired through an
interactive session are examples. For those, the `resolve()` call omits
`fetch_fn` and the function falls through directly from tier 2 to tier 4 (loud
stop) if the file is missing. Do not fabricate a `fetch_fn` that can't actually
re-fetch; a clean failure is better than a broken recipe.

`validate` is also optional. It's a predicate `function(path) -> logical`
that `resolve()` calls on any local or Drive hit. Returning `TRUE` accepts the
file; returning `FALSE` (or throwing) treats the hit as absent and falls
through to the next tier.

### Root resolution — use `here`, never `setwd()`

A `.here` sentinel at `~/MIH/.here` anchors the project. Every script starts:

```r
library(here)
ROOT        <- here::here()
DATA_FIELD  <- file.path(ROOT, "data/field")
DATA_PUBLIC <- file.path(ROOT, "data/public")
OUTPUTS     <- file.path(ROOT, "outputs")
```

A `.here` sentinel at `~/MIH/.here` anchors the project. `here::here()` walks up
from R's current working directory until it finds the sentinel, returning
`~/MIH`. The standard workflow is to open `MIH.Rproj` in RStudio, which sets
cwd to `~/MIH`; `here()` then resolves correctly from any script in `scripts/`.
No hardcoded usernames. No `ROOT <- "."`.

## Directory structure

```
~/MIH/
├── scripts/                              ← all pipeline and utility scripts
│   ├── _pipeline_boilerplate.R           ← sourced by every script (resolve, push_output, constants)
│   ├── 00_occurrence.R                   ← step 00: occurrence staging
│   ├── 01a_build_canonical_rasters.R     ← sub-step 01a: USGS 3DEP → canonical DEM + island index
│   ├── 01b_aggregate_rh.R                ← sub-step 01b: HCDP daily RH → monthly
│   ├── 01c_aggregate_ndvi.R              ← sub-step 01c: HCDP daily NDVI → monthly MVC
│   ├── 01d_decade_normals.R              ← sub-step 01d: ERA5 downscale + HCDP/Rainfall Atlas → decade normals
│   ├── 01e_extract_climate_atlas.R       ← sub-step 01e: RAR → GeoTIFF
│   ├── 01_env_layers.R                   ← step 01: env predictor stacks (main)
│   ├── 02_occurrence_clean.R             ← step 02: QC + thinning
│   ├── 03_enm.R                          ← step 03: ENMeval MaxEnt × 6
│   ├── 04_area_stats.R                   ← step 04: area + Venn
│   ├── 05_niche_overlap.R                ← step 05: ecospat
│   ├── 06_survey_model.R                 ← step 06: ZINB on field data
│   ├── 07_figures.R                      ← step 07: manuscript figures
│   └── MIH_*.R                           ← utility scripts (audit, push, etc.)
├── data/
│   ├── field/                       ← Jon's irreplaceable survey data
│   │   ├── mtr.csv                  ← MosquiTrap, 495 trap events
│   │   ├── ibuttondata.csv          ← iButton T/RH, 8 sites
│   │   ├── sitedata.xls             ← site GPS, iButton serials, elevations
│   │   ├── 1966_aegypti_presence.csv
│   │   ├── 2002_aegypti_presence.csv
│   │   ├── 2002_DOH.csv
│   │   └── allyears_allspp_pres_maxent.csv
│   └── public/                      ← raw downloads, step-prefixed
│       └── (see STATUS.md for the current acquired-file inventory)
├── bibliography/                    ← cited PDFs; index in MIH_bibliography.md
├── outputs/
│   ├── 00_occurrence/  01_env_layers/  02_occurrence_clean/
│   ├── 03_enm/         04_area_stats/  05_niche_overlap/
│   ├── 06_survey_model/  07_figures/
└── .here                            ← here() sentinel
```

Drive mirrors local path-for-path under `MIH_Mosquitoes_Hawaii/`. Forward-slash
paths throughout (no underscore aliases). Mismatches cause files to appear missing
on both sides simultaneously — fix at source, never in audit logic.
