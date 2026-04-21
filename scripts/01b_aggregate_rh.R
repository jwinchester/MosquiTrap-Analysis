## 01b_aggregate_rh.R — Aggregate HCDP daily RH to monthly means (2002–2011)
## MIH Pipeline Sub-step 01b
##
## ⚑ FLAG [RH quality]: HCDP daily RH spatial model has poor cross-validation
##   performance (LOOCV R² median 0.179, RMSE median 12.2%; see PROVENANCE.md).
##   Output here is retained for exploratory use only — do NOT derive VPD
##   from it. Use Climate Atlas VPD_month (sub-step 01e) for landscape VPD.
## ────────────────────────────────────────────────────────────────────────────

library(conflicted)
library(here)
library(terra)
library(stringr)
library(googledrive)

conflicted::conflicts_prefer(terra::extract)
conflicted::conflicts_prefer(base::intersect)
conflicted::conflicts_prefer(base::setdiff)

source(here::here("scripts/_pipeline_boilerplate.R"))

## -- Paths ------------------------------------------------------------------

ROOT        <- here::here()
DATA_FIELD  <- file.path(ROOT, "data/field")
DATA_PUBLIC <- file.path(ROOT, "data/public")
OUTDIR      <- file.path(ROOT, "outputs")
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

bundle_rel <- "outputs/01b_rh_monthly_2002_2011.zip"
bundle_abs <- here::here(bundle_rel)

## -- Resolve inputs ---------------------------------------------------------

## HCDP daily RH zip — tiers 1 and 2 only. HCDP downloads are API-keyed and
## built interactively against the data portal, so no fetch_fn. If neither
## local nor Drive has the file, fail loudly and re-request manually from
## api.hcdp.ikewai.org.
f_zip <- resolve("data/public/01_HCDP_rh_daily_2002_2011.zip",
                  "MIH_Mosquitoes_Hawaii/data/public/01_HCDP_rh_daily_2002_2011.zip")

## ── 1. Scratch directory ───────────────────────────────────────────────────

## mih_new_scratch() returns an isolated working directory AND redirects
## terra's internal temp files to a separate directory so terra's housekeeping
## can't evict our scratch files. Cleanup on R exit is registered automatically
## — no on.exit() required. See PIPELINE_SPEC "Working-files pattern".

scratch <- mih_new_scratch("mih_01b_")

extract_dir <- file.path(scratch, "extract")
scratch_dir <- file.path(scratch, "out")
dir.create(extract_dir)
dir.create(scratch_dir)

unzip(f_zip, exdir = extract_dir)

tifs <- list.files(extract_dir, pattern = "\\.tif$", recursive = TRUE,
                   full.names = TRUE, ignore.case = TRUE)

## ── 2. Parse year-month from filenames ─────────────────────────────────────

## Per PIPELINE_SPEC appendix — `data/public/` catalog:
##   contents: 3,652 GeoTIFFs
##   naming : relative_humidity_day_statewide_data_map_YYYY_MM_DD.tif
## Match the exact pattern (anchored) so any future repackaging change fails
## loudly rather than being silently absorbed.

rh_pat    <- "^relative_humidity_day_statewide_data_map_(\\d{4})_(\\d{2})_(\\d{2})\\.tif$"
dm        <- stringr::str_match(basename(tifs), rh_pat)
stopifnot(!anyNA(dm[, 1]))        # every TIF must match the documented pattern
stopifnot(length(tifs) == 3652L)  # per catalog — coverage complete as shipped

yr     <- dm[, 2]
mo     <- dm[, 3]
ym_key <- paste(yr, mo, sep = "_")

## 10 years (2002–2011) × 12 months = 120 unique year-months.
unique_ym <- sort(unique(ym_key))
stopifnot(length(unique_ym) == 120L)

cat(sprintf("Zip contains %d daily grids across %d year-months.\n",
            length(tifs), length(unique_ym)))

## ── 3. Filter to readable files ────────────────────────────────────────────

## Per PROVENANCE.md — HCDP daily-product gap convention:
##   HCDP ships one file per calendar day regardless of data availability.
##   Gap days (instrument outage, cloud cover, QC fail) are delivered as
##   zero-byte TIFs. A small residual of non-zero-byte files may fail GDAL
##   parse (truncated during packaging). Both classes are methodologically
##   indistinguishable from gap days for aggregation and must be silently
##   skipped. Pattern mirrors 01c_aggregate_ndvi.R.
##
## Empirical test on rh_daily (prior run): 0 zero-byte, 0 GDAL-fail — clean.
## Filter retained as defence-in-depth in case a future re-delivery differs.

is_readable <- function(path) {
  if (file.size(path) == 0L) return(FALSE)
  suppressWarnings(tryCatch({
    terra::rast(path)
    TRUE
  }, error = function(e) FALSE))
}

sizes      <- file.size(tifs)
n_zerobyte <- sum(sizes == 0L)

readable <- vapply(tifs, is_readable, logical(1L), USE.NAMES = FALSE)
n_gdalfail <- sum(!readable & sizes > 0L)
n_valid    <- sum(readable)

cat(sprintf("Readable: %d/%d  (zero-byte: %d, GDAL-fail: %d)\n",
            n_valid, length(tifs), n_zerobyte, n_gdalfail))

tifs   <- tifs[readable]
yr     <- yr[readable]
mo     <- mo[readable]
ym_key <- ym_key[readable]

stopifnot(all(unique_ym %in% ym_key))  # no month wiped out entirely

## ── 4. Compute monthly means into scratch_dir ──────────────────────────────

for (ym in unique_ym) {
  grids <- tifs[ym_key == ym]
  out   <- file.path(scratch_dir, paste0("rh_monthly_", ym, ".tif"))

  r_stk  <- terra::rast(grids)
  r_mean <- terra::app(r_stk, fun = mean, na.rm = TRUE)

  terra::writeRaster(
    r_mean, out,
    datatype  = "FLT4S",
    overwrite = TRUE,
    gdal      = c("COMPRESS=DEFLATE", "PREDICTOR=3", "TILED=YES")
  )

  cat(sprintf("  %s  (%2d valid daily grids)\n", ym, length(grids)))
}

## ── 5. Bundle scratch into zip and push ────────────────────────────────────

## Flat layout (-j strips scratch_dir path prefix). utils::zip returns 0 on
## success; anything else is a fatal packaging failure.

if (file.exists(bundle_abs)) file.remove(bundle_abs)

zip_status <- utils::zip(
  zipfile = bundle_abs,
  files   = list.files(scratch_dir, full.names = TRUE),
  flags   = "-j9"
)
stopifnot(zip_status == 0L)

push_output(bundle_abs, bundle_rel)

cat(sprintf("\nSub-step 01b complete. Bundle: %s (%d monthly RH grids)\n",
            bundle_abs, length(unique_ym)))
