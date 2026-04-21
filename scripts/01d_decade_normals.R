## 01d_decade_normals.R — Contemporary decade climatological normals
## MIH Pipeline Sub-step 01d
## ────────────────────────────────────────────────────────────────────────────
## Produces contemporary (2002–2011) HCDP monthly normals: 12 tmin, 12 tmax,
## 12 rainfall. Historic period retired from this script per STATUS.md
## decision #17 (historic analyses use WorldClim v1.4 via main 01_env_layers).
## See PIPELINE_SPEC Step 01 sub-step 01d for the full contract.

library(here)
library(conflicted)
library(googledrive)
library(terra)

source(here::here("scripts/_pipeline_boilerplate.R"))

conflicts_prefer(dplyr::filter, dplyr::lag, dplyr::select,
                 terra::extract, base::intersect, base::setdiff)

## -- Paths & constants -------------------------------------------------------

ROOT   <- here::here()
OUTDIR <- file.path(ROOT, "outputs")
BUNDLE <- file.path(OUTDIR, "01d_contemporary_normals_2002_2011.zip")
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

YEARS  <- 2002:2011
MONTHS <- 1:12

## -- Resolve inputs ----------------------------------------------------------

zip_validator <- function(min_mb) {
  force(min_mb)
  function(path) {
    file.info(path)$size > min_mb * 1024 * 1024 &&
      !inherits(try(utils::unzip(path, list = TRUE), silent = TRUE), "try-error")
  }
}

f_tmax <- resolve(
  "data/public/01_HCDP_tmax_month_2002_2011.zip",
  "MIH_Mosquitoes_Hawaii/data/public/01_HCDP_tmax_month_2002_2011.zip",
  validate = zip_validator(50)
)
f_tmin <- resolve(
  "data/public/01_HCDP_tmin_month_2002_2011.zip",
  "MIH_Mosquitoes_Hawaii/data/public/01_HCDP_tmin_month_2002_2011.zip",
  validate = zip_validator(50)
)
f_rf <- resolve(
  "data/public/01_HCDP_rainfall_month_2002_2011.zip",
  "MIH_Mosquitoes_Hawaii/data/public/01_HCDP_rainfall_month_2002_2011.zip",
  validate = zip_validator(50)
)
f_dem <- resolve(
  "data/public/01_DEM_hawaii_statewide_canonical.tif",
  "MIH_Mosquitoes_Hawaii/data/public/01_DEM_hawaii_statewide_canonical.tif",
  validate = function(path) {
    r <- try(terra::rast(path), silent = TRUE)
    !inherits(r, "try-error") && all(dim(r)[1:2] == c(1520L, 2288L))
  }
)

dem_250m  <- terra::rast(f_dem)
land_mask <- dem_250m > 0

## -- Scratch dir (torn down on process exit via mih_new_scratch) ------------

scratch <- mih_new_scratch("01d_")

## ── Phase 1: HCDP monthly normals per variable ───────────────────────────────
## Read monthlies via /vsizip/ rather than extracting — faster on a fresh run
## and avoids disk pressure from 360 TIFs when only 36 outputs are retained.
## Rainfall is masked to canonical land (dem_250m > 0) BEFORE averaging to
## close the 298-cell ocean-leak gap between HCDP rainfall's geostatistical
## footprint and the canonical DEM coastline.

hcdp_monthly_normals <- function(zip_path, var_pattern, out_prefix,
                                 mask_to_land = FALSE) {
  entries <- utils::unzip(zip_path, list = TRUE)$Name
  for (m in MONTHS) {
    acc <- NULL
    for (yr in YEARS) {
      pat <- sprintf("%s_%04d_%02d\\.tif$", var_pattern, yr, m)
      hit <- grep(pat, entries, value = TRUE)
      if (length(hit) != 1L) {
        stop("HCDP pattern not unique: ", pat, " in ", basename(zip_path),
             " (matched ", length(hit), ")")
      }
      r <- terra::rast(sprintf("/vsizip/%s/%s", zip_path, hit))
      if (mask_to_land) r <- terra::mask(r, land_mask, maskvalues = c(NA, FALSE))
      acc <- if (is.null(acc)) r else acc + r
    }
    norm <- acc / length(YEARS)
    terra::writeRaster(norm,
      file.path(scratch, sprintf("%s_%02d.tif", out_prefix, m)),
      overwrite = TRUE, datatype = "FLT4S", gdal = "COMPRESS=LZW")
    message(sprintf("  %s month %02d done", out_prefix, m))
  }
}

message("Phase 1: HCDP contemporary monthly normals")
hcdp_monthly_normals(f_tmax, "temperature_max_month_statewide_data_map",
                     "tmax_normal")
hcdp_monthly_normals(f_tmin, "temperature_min_month_statewide_data_map",
                     "tmin_normal")
hcdp_monthly_normals(f_rf,   "rainfall_new_month_statewide_data_map",
                     "rf_normal", mask_to_land = TRUE)

## ── Phase 2: Coastal-fringe fill for tmax/tmin ───────────────────────────────
##
## ⚑ FLAG [coastal temp fill]: nearest-neighbor fill applied to tmax/tmin
## normals to extend coverage from the temperature product's DEM-based land
## mask to the rainfall product's geostatistical footprint. Low-elevation
## coastal cells only (DEM > 0). See PROVENANCE.md — HCDP temperature vs
## rainfall land mask mismatch.

message("Phase 2: coastal-fringe fill")

## Footprint = union of post-mask rainfall-normal land across all 12 months
## AND DEM > 0. Masking rainfall to canonical land in Phase 1 makes these
## equivalent in theory; Reducing over 12 months is defence-in-depth against
## any single month's mask corner case.
rf_any <- Reduce(`|`, lapply(MONTHS, function(m) {
  !is.na(terra::rast(file.path(scratch, sprintf("rf_normal_%02d.tif", m))))
}))
footprint <- rf_any & land_mask

log_rows <- list()
for (var in c("tmax", "tmin")) {
  for (m in MONTHS) {
    p      <- file.path(scratch, sprintf("%s_normal_%02d.tif", var, m))
    p_tmp  <- sub("\\.tif$", "_filled.tif", p)
    r      <- terra::rast(p)

    n_before <- unname(terra::global(r, "notNA", na.rm = TRUE)[1, 1])
    r_filled <- terra::focal(r, w = 3, fun = "mean",
                             na.policy = "only", na.rm = TRUE)
    r_masked <- terra::mask(r_filled, footprint,
                            maskvalues = c(NA, FALSE))
    n_after  <- unname(terra::global(r_masked, "notNA", na.rm = TRUE)[1, 1])

    terra::writeRaster(r_masked, p_tmp, overwrite = TRUE,
                       datatype = "FLT4S", gdal = "COMPRESS=LZW")
    ## Rename-over avoids terra's read-while-writing hazard on the same path.
    file.rename(p_tmp, p)

    log_rows[[length(log_rows) + 1L]] <- data.frame(
      variable          = var,
      month             = m,
      cells_before_fill = n_before,
      cells_after_fill  = n_after,
      cells_filled      = n_after - n_before
    )
    message(sprintf("  %s month %02d filled %d cells", var, m, n_after - n_before))
  }
}
utils::write.csv(do.call(rbind, log_rows),
                 file.path(scratch, "coastal_fill_log.csv"),
                 row.names = FALSE)

## ── Phase 3: Bundle & push ───────────────────────────────────────────────────
## Flat layout — single period, no subdirs. Explicit scratch-state assertions
## before zip catch any drift between Phase 1/2 file counts and the expected
## 36 TIFs + 1 CSV. -j flattens per spec.

stopifnot(dir.exists(scratch))
n_tifs <- length(list.files(scratch, pattern = "\\.tif$"))
n_csvs <- length(list.files(scratch, pattern = "\\.csv$"))
if (n_tifs != 36L || n_csvs != 1L) {
  stop("Scratch count wrong: ", n_tifs, " TIFs, ", n_csvs,
       " CSVs (expected 36, 1)")
}

if (file.exists(BUNDLE)) {
  if (!file.remove(BUNDLE)) stop("Could not remove prior bundle: ", BUNDLE)
}

## Explicit shell `cd` + zip to avoid utils::zip's cwd-propagation history
## (see earlier zip-failure diagnosis). `-j9` flattens with max compression.
zip_cmd <- sprintf("cd %s && zip -j9 %s *.tif *.csv",
                   shQuote(scratch), shQuote(BUNDLE))
zip_rc <- system(zip_cmd)
if (zip_rc != 0L) stop("zip failed (rc=", zip_rc, "): ", zip_cmd)

if (!file.exists(BUNDLE) || file.info(BUNDLE)$size < 1024L) {
  stop("Bundle missing or suspiciously small after zip: ", BUNDLE)
}

push_output(BUNDLE, "outputs/01d_contemporary_normals_2002_2011.zip")

message(sprintf("\nStep 01d complete: %d TIFs + %d logs bundled in %s",
                n_tifs, n_csvs, basename(BUNDLE)))
