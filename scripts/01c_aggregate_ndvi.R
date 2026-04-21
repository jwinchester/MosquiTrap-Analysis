## 01c_aggregate_ndvi.R — HCDP daily NDVI → monthly MVC
## MIH Pipeline Sub-step 01c
## ────────────────────────────────────────────────────────────────────────────
##
## Purpose:
##   Aggregate HCDP daily MODIS NDVI grids to monthly composites for the
##   contemporary period using Maximum Value Composite (MVC) — per pixel,
##   the highest NDVI across the month. Standard MODIS compositing technique
##   to minimise cloud contamination.
##
## Input:
##   data/public/01_HCDP_ndvi_daily_2002_2011.zip
##     - 3,584 GeoTIFFs
##     - filename pattern: ndvi_modis_day_statewide_data_map_YYYY_MM_DD.tif
##     - period: Mar 10, 2002 – Dec 31, 2011
##
## Output:
##   outputs/01c_ndvi_monthly_2002_2011.zip
##     Contains 118 ndvi_monthly_YYYY_MM.tif files (Mar 2002 – Dec 2011)
##     plus _ndvi_coverage.txt (per-month daily-grid coverage, methods
##     provenance). Flat layout via zip -j9. Pushed to Drive at that path.
##
## Working pattern:
##   Two scratch dirs via mih_new_scratch() — one for unzipped archive,
##   one for monthly MVCs. The helper also isolates terra's internal
##   tempdir so terra's housekeeping can't sweep files the script still
##   needs. Both scratch dirs are cleaned up on R process exit; no manual
##   on.exit() required.
##
## Known data-quality conditions (empirically verified; see PROVENANCE.md):
##
##   Product-start gap:
##     MODIS availability starts Mar 10, 2002, so 2002-01 and 2002-02 have
##     no daily grids. Monthly output is 118 files, not 120.
##
##   HCDP unavailable-day convention:
##     HCDP ships one file per calendar day regardless of data availability.
##     Days with no valid MODIS observations (instrument outage, total cloud
##     cover, quality-screening failures) are delivered as zero-byte TIFs.
##     This archive: ~56 zero-byte files (~1.6% of 3,584). Filtered by
##     file.size() > 0 without touching GDAL.
##
##   Residual unreadable files:
##     ~18 files (~0.5%) are non-zero-byte but fail GDAL header parse.
##     Most likely truncated during HCDP's zip packaging. Caught via
##     withCallingHandlers + tryCatch and treated identically to gap days.
##
##   Methodological impact:
##     Bad-file distribution is scattered (1–3 per month), not batched. MVC
##     over 28 readable days is indistinguishable from MVC over 31; missing
##     days are silently absorbed. A month with zero readable files would
##     be a genuine archive failure and is handled as fatal with a pointer
##     to MIH_diagnose_ndvi.R.
##
## Correctness notes:
##
##   NA-safe MVC:
##     terra::app(fun = "max", na.rm = TRUE) returns -Inf when every layer's
##     value at a pixel is NA (plausible for ocean cells or masked regions).
##     -Inf propagates downstream and is not a valid NDVI value. This script
##     uses terra::ifel(is.finite(mvc), mvc, NA_real_) after the max to
##     convert -Inf back to NA explicitly.
##
##   Narrow warning handling:
##     The GDAL "not recognized as a supported file format" warning fires
##     alongside the error on truncated TIFs. withCallingHandlers muffles
##     that specific message while letting any other warning surface normally
##     (so a new, genuine warning from terra wouldn't be silently hidden).
##
##   Geometry assertion:
##     The first readable file of the first month sets the reference grid.
##     Every subsequent month's first readable file is checked against that
##     reference via terra::compareGeom. An unexpected grid mismatch stops
##     loudly rather than silently aligning or half-failing at stack time.
##
##   Archive validation:
##     The input zip is resolved with a validate predicate — a ~1 GB size
##     floor plus a zip directory smoke test via utils::unzip(..., list = TRUE).
##     A truncated cached download from an interrupted prior copy fails
##     validation and falls through to the Drive tier rather than being
##     silently used as an incomplete archive.

library(conflicted)
library(here)
library(terra)
library(stringr)
library(googledrive)

conflicted::conflicts_prefer(base::intersect)
conflicted::conflicts_prefer(base::setdiff)

source(here::here("scripts/_pipeline_boilerplate.R"))

## ── 1. Resolve input ──────────────────────────────────────────────────────
## Archive is ~3.8 GB per the data/public catalog. Size floor of 1 GB is
## generous enough to accept any plausible complete delivery while catching
## truncated caches from interrupted copies. The zip-directory read is a
## fast structural sanity check — parses the central directory to confirm
## the archive is well-formed without extracting anything.

f_zip <- resolve(
  local_path = "data/public/01_HCDP_ndvi_daily_2002_2011.zip",
  drive_path = "MIH_Mosquitoes_Hawaii/data/public/01_HCDP_ndvi_daily_2002_2011.zip",
  validate   = function(path) {
    if (file.info(path)$size < 1e9) return(FALSE)
    lst <- tryCatch(utils::unzip(path, list = TRUE), error = function(e) NULL)
    !is.null(lst) && nrow(lst) > 0
  }
)

## ── 2. Scratch directories ────────────────────────────────────────────────
## One scratch for the unzipped archive, one for monthly MVC outputs.
## mih_new_scratch() also redirects terra's internal tempdir to an
## isolated location so terra's housekeeping can't remove files the
## script still needs. No manual cleanup — both scratch dirs are removed
## when R exits (normal, error, or session close).

extract_dir <- mih_new_scratch("mih_01c_extract_")
scratch     <- mih_new_scratch("mih_01c_scratch_")

unzip(f_zip, exdir = extract_dir)

## ── 3. Identify and parse daily NDVI files ────────────────────────────────
## Exact filename convention from the data/public catalog appendix:
##   ndvi_modis_day_statewide_data_map_YYYY_MM_DD.tif
## Restrict to this pattern so stray files (metadata, READMEs) don't leak in.
## Count-assert against the appendix; any divergence stops so we don't
## silently process a different archive than the one catalogued.

FNAME_RE <- "^ndvi_modis_day_statewide_data_map_(\\d{4})_(\\d{2})_(\\d{2})\\.tif$"
EXPECTED_DAILY <- 3584L

all_tifs <- list.files(extract_dir, pattern = "\\.tif$", recursive = TRUE,
                       full.names = TRUE, ignore.case = TRUE)
matches  <- stringr::str_match(basename(all_tifs), FNAME_RE)
ok       <- !is.na(matches[, 1])
daily_files <- all_tifs[ok]
daily_meta  <- matches[ok, , drop = FALSE]

if (length(daily_files) != EXPECTED_DAILY) {
  stop("Daily file count mismatch: found ", length(daily_files),
       ", expected ", EXPECTED_DAILY, " per data/public catalog.\n",
       "  Archive integrity failed; run MIH_diagnose_ndvi.R for detail.")
}

dates <- as.Date(sprintf("%s-%s-%s",
                         daily_meta[, 2], daily_meta[, 3], daily_meta[, 4]))
yrmo  <- format(dates, "%Y_%m")

## ── 4. Helpers ────────────────────────────────────────────────────────────

## Narrow handler: muffle only the specific GDAL "not recognized" warning
## that fires alongside errors on truncated TIFs. Any other warning from
## terra::rast surfaces normally — we want to see those.
try_open <- function(path) {
  withCallingHandlers(
    tryCatch(terra::rast(path), error = function(e) e),
    warning = function(w) {
      if (grepl("not recognized as a supported file format",
                conditionMessage(w), fixed = TRUE)) {
        invokeRestart("muffleWarning")
      }
    }
  )
}

## NA-safe max across layers: returns NA_real_ when every input is NA.
## Built-in terra::app(fun = "max", na.rm = TRUE) returns -Inf in that case.
## Post-processing via terra::ifel is cleaner than a user-supplied R function
## (which would forfeit terra's C++ fast path for named aggregations).
mvc_from_stack <- function(r) {
  out <- terra::app(r, fun = "max", na.rm = TRUE)
  terra::ifel(is.finite(out), out, NA_real_)
}

## ── 5. Compute MVC per year-month ─────────────────────────────────────────
## For each month:
##   1. Drop zero-byte files (HCDP gap convention).
##   2. Probe remaining files; partition into readable / unreadable.
##   3. If no readable files remain, stop (archive failure).
##   4. Assert geometry matches the reference (first readable of month 1).
##   5. Compute MVC (NA-safe) and write GeoTIFF into scratch.
##   6. Record counts for the coverage log.

coverage <- data.frame(
  year_month = character(),
  readable   = integer(),
  zero_byte  = integer(),
  other_bad  = integer(),
  total      = integer(),
  stringsAsFactors = FALSE
)

## Reference geometry is locked in from the first readable file encountered.
ref_rast <- NULL

keys  <- sort(unique(yrmo))
n_out <- length(keys)
cat(sprintf("Aggregating %d daily grids into %d monthly composites (%s – %s).\n",
            length(daily_files), n_out, keys[1], keys[n_out]))

for (i in seq_along(keys)) {
  key            <- keys[i]
  paths_in_month <- daily_files[yrmo == key]

  ## 5.1: zero-byte filter (HCDP gap convention) — no GDAL call
  sizes      <- file.size(paths_in_month)
  zero_mask  <- sizes == 0L
  candidates <- paths_in_month[!zero_mask]

  ## 5.2: probe non-zero-byte files for openability
  opens <- logical(length(candidates))
  for (j in seq_along(candidates)) {
    res <- try_open(candidates[j])
    opens[j] <- !inherits(res, "error")
  }
  good_paths <- candidates[opens]

  n_zero  <- sum(zero_mask)
  n_other <- sum(!opens)

  ## 5.3: fatal only if the month is entirely unreadable
  if (length(good_paths) == 0) {
    stop("All ", length(paths_in_month), " daily grids for ", key,
         " are unreadable (", n_zero, " zero-byte, ", n_other, " other).",
         "\n  Archive is severely damaged for this month.",
         "\n  Run MIH_diagnose_ndvi.R for per-file detail and re-request",
         "\n  from HCDP if needed.")
  }

  ## 5.4: geometry assertion against the reference grid
  first_r <- terra::rast(good_paths[1])
  if (is.null(ref_rast)) {
    ref_rast <- first_r
  } else if (!terra::compareGeom(first_r, ref_rast,
                                 stopOnError = FALSE, messages = FALSE)) {
    stop("Geometry mismatch in ", basename(good_paths[1]),
         " vs reference (first readable file of ", keys[1], ").",
         "\n  Expected grid (from appendix): WGS84, ~0.00225°, dims 1520x2288.",
         "\n  Archive may contain a mixed-grid delivery; inspect with terra::rast.")
  }

  ## 5.5: MVC (NA-safe) and write to scratch
  r   <- terra::rast(good_paths)
  mvc <- mvc_from_stack(r)

  out_path <- file.path(scratch, sprintf("ndvi_monthly_%s.tif", key))
  terra::writeRaster(
    mvc, out_path,
    overwrite = TRUE,
    datatype  = "FLT4S",
    gdal      = c("COMPRESS=DEFLATE", "PREDICTOR=3", "TILED=YES")
  )

  ## 5.6: coverage bookkeeping
  coverage <- rbind(coverage, data.frame(
    year_month = key,
    readable   = length(good_paths),
    zero_byte  = n_zero,
    other_bad  = n_other,
    total      = length(paths_in_month),
    stringsAsFactors = FALSE
  ))

  if (i %% 12 == 0 || i == n_out) {
    cat(sprintf("  %d / %d composites written\n", i, n_out))
  }
}

## ── 6. Write coverage log into scratch ────────────────────────────────────

total_readable <- sum(coverage$readable)
total_days     <- sum(coverage$total)
total_zero     <- sum(coverage$zero_byte)
total_other    <- sum(coverage$other_bad)

cov_txt_path <- file.path(scratch, "_ndvi_coverage.txt")
cov_lines <- c(
  "HCDP NDVI monthly MVC — per-month daily-grid coverage",
  paste("Generated:", Sys.time()),
  paste("Archive:", f_zip),
  "",
  "Overall:",
  sprintf("  Monthly composites written: %d (Mar 2002 – Dec 2011)", n_out),
  sprintf("  Daily grids contributing:   %d / %d  (%.2f%%)",
          total_readable, total_days, 100 * total_readable / total_days),
  sprintf("  Zero-byte (HCDP unavailable-day convention): %d", total_zero),
  sprintf("  Other unreadable (likely packaging truncation): %d", total_other),
  "",
  "Per month (readable / total  [detail if any unreadable]):"
)

for (k in seq_len(nrow(coverage))) {
  row    <- coverage[k, ]
  detail <- if (row$readable < row$total) {
    sprintf("   [%d zero-byte, %d other-bad]",
            row$zero_byte, row$other_bad)
  } else ""
  cov_lines <- c(cov_lines,
    sprintf("  %s: %d / %d%s",
            row$year_month, row$readable, row$total, detail)
  )
}

writeLines(cov_lines, cov_txt_path)

## ── 7. Bundle scratch into zip output and push to Drive ───────────────────
## Canonical working-files pattern from PIPELINE_SPEC: zip the entire
## scratch dir (flat layout via -j, max compression via -9). TIFs already
## have internal DEFLATE so compression gain is mostly on the text log.

bundle_rel  <- "outputs/01c_ndvi_monthly_2002_2011.zip"
bundle_path <- here::here(bundle_rel)
dir.create(dirname(bundle_path), recursive = TRUE, showWarnings = FALSE)

cat(sprintf("\nBundling scratch contents into %s\n", basename(bundle_path)))

zip_status <- utils::zip(
  zipfile = bundle_path,
  files   = list.files(scratch, full.names = TRUE, recursive = TRUE),
  flags   = "-j9"
)

if (zip_status != 0L || !file.exists(bundle_path)) {
  stop("Bundle creation failed (zip exit status ", zip_status, ").",
       "\n  Expected output: ", bundle_path)
}

push_output(bundle_path, bundle_rel)

## ── 8. Final summary ──────────────────────────────────────────────────────

cat(sprintf("\nSub-step 01c complete. %d composites bundled.\n", n_out))
cat(sprintf("Coverage: %d/%d daily grids contributed (%.2f%%).\n",
            total_readable, total_days,
            100 * total_readable / total_days))
cat(sprintf("Bundle: %s (%.1f MB)\n",
            bundle_path, file.size(bundle_path) / 1024^2))
