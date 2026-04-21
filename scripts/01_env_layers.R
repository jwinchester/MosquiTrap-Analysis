## 01_env_layers.R -- Assemble environmental predictor stacks
## MIH Pipeline Step 01 (main)
## ---------------------------------------------------------------------------
## Reads zip bundles from sub-steps 01a-01e and produces THREE multi-layer
## GeoTIFF stacks:
##   Track A Contemporary (2002-2011, 250m HCDP + Climate Atlas)
##   Track B Contemporary (1970-2000 baseline, ~1km WorldClim v2.1)
##   Track B Historic     (1960-1990 baseline, ~1km WorldClim v1.4)
##
## Track A Historic was retired after GHCN station validation revealed
## structural ERA5-Land bias at Hawaii (decision #17, April 19 2026).
## Historic analyses use Track B Historic regardless of the contemporary
## track being compared. See PROVENANCE.md -> ERA5 station validation.
##
## Sub-steps (zip bundles / files consumed):
##   01a -> data/public/01_DEM_hawaii_statewide_canonical.tif
##          data/public/01_island_index.tif
##   01d -> outputs/01d_contemporary_normals_2002_2011.zip
##   01e -> outputs/01e_climate_atlas_geotiff.zip
##   (01b, 01c not consumed here -- retained for exploratory analysis)
## ---------------------------------------------------------------------------

library(here)
library(conflicted)
library(googledrive)
library(terra)
library(dismo)

conflicted::conflicts_prefer(terra::extract, base::intersect, base::setdiff)

source(here::here("scripts/_pipeline_boilerplate.R"))
options(warn = 1)  # print warnings inline, not deferred

## -- Paths -------------------------------------------------------------------

ROOT        <- here::here()
DATA_PUBLIC <- file.path(ROOT, "data/public")
OUTDIR      <- file.path(ROOT, "outputs")
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

## -- Scratch directory -------------------------------------------------------

scratch <- mih_new_scratch("mih_01main_")

## -- Configuration -----------------------------------------------------------

ATLAS_VARS      <- c("vpd", "rh", "evi", "ndvi", "fvc", "cloudfreq")
ATLAS_SUMMARIES <- c("min", "max", "ann")
ATLAS_UNITS     <- c(vpd = "Pa", rh = "%", evi = "index",
                     ndvi = "index", fvc = "ratio", cloudfreq = "ratio")

HAWAII_EXT <- terra::ext(-160.5, -154.5, 18.5, 22.5)

BIO_NAMES <- paste0("bio", 1:19)
BIO_UNITS <- c("C", "C", "ratio*100", "SD*100", "C", "C", "C",
               "C", "C", "C", "C", "mm", "mm", "mm",
               "CV*100", "mm", "mm", "mm", "mm")

## -- Timing and log ----------------------------------------------------------

t_start   <- Sys.time()
timings   <- list()
log_lines <- character()

log_msg <- function(...) {
  msg <- paste0(...)
  cat(msg, "\n")
  log_lines <<- c(log_lines, msg)
}

log_msg("=== MIH Pipeline -- Step 01: Environmental Layers ===")
log_msg("Date: ", format(t_start))
log_msg("")

## ============================================================================
## RESOLVE INPUTS
## ============================================================================

## Canonical DEM (from 01a)
dem_canonical_path <- resolve(
  "data/public/01_DEM_hawaii_statewide_canonical.tif",
  "MIH_Mosquitoes_Hawaii/data/public/01_DEM_hawaii_statewide_canonical.tif"
)
dem_canonical <- terra::rast(dem_canonical_path)

## Island index (from 01a) -- verify it exists
resolve(
  "data/public/01_island_index.tif",
  "MIH_Mosquitoes_Hawaii/data/public/01_island_index.tif"
)

## Contemporary normals (from 01d -- rescoped to contemporary-only per decision #17)
zip_01d <- resolve(
  "outputs/01d_contemporary_normals_2002_2011.zip",
  "MIH_Mosquitoes_Hawaii/outputs/01d_contemporary_normals_2002_2011.zip"
)

## Climate Atlas GeoTIFFs (from 01e)
zip_01e <- resolve(
  "outputs/01e_climate_atlas_geotiff.zip",
  "MIH_Mosquitoes_Hawaii/outputs/01e_climate_atlas_geotiff.zip"
)

## WorldClim v2.1 (Track B contemporary)
wc21_zip <- resolve(
  "data/public/01_WorldClim_wc2.1_30s_bio.zip",
  "MIH_Mosquitoes_Hawaii/data/public/01_WorldClim_wc2.1_30s_bio.zip",
  fetch_fn = function(path) {
    utils::download.file(
      "https://geodata.ucdavis.edu/climate/worldclim/2_1/base/wc2.1_30s_bio.zip",
      destfile = path, mode = "wb")
  }
)

## WorldClim v1.4 (Track B historic -- also serves as historic reference
## for any Track A x historic comparison per decision #17)
wc14_zip <- resolve(
  "data/public/01_WorldClim_wc1.4_30s_bio.zip",
  "MIH_Mosquitoes_Hawaii/data/public/01_WorldClim_wc1.4_30s_bio.zip"
)

## -- Extract zip bundles to scratch ------------------------------------------

normals_dir <- file.path(scratch, "normals")
atlas_dir   <- file.path(scratch, "atlas")
dir.create(normals_dir)
dir.create(atlas_dir)

log_msg("Extracting 01d contemporary normals bundle...")
utils::unzip(zip_01d, exdir = normals_dir)

log_msg("Extracting 01e Climate Atlas bundle...")
utils::unzip(zip_01e, exdir = atlas_dir)

## -- Verify sub-step contents ------------------------------------------------

check_inputs <- function() {
  months_02 <- sprintf("%02d", 1:12)
  checks <- list()

  ## 01d is contemporary-only -- no normals_1957_1966 expected
  for (var in c("tmax", "tmin", "rf")) {
    checks[[paste("normals_2002_2011", var)]] <- file.path(
      normals_dir, paste0(var, "_normal_", months_02, ".tif"))
  }

  for (var in ATLAS_VARS) {
    checks[[paste("climate_atlas", var)]] <- c(
      file.path(atlas_dir, paste0(var, "_", months_02, ".tif")),
      file.path(atlas_dir, paste0(var, "_ann.tif")))
  }

  all_ok <- TRUE
  for (group in names(checks)) {
    files <- checks[[group]]
    n_missing <- sum(!file.exists(files))
    if (n_missing > 0) {
      log_msg("  MISSING: ", group, " -- ", n_missing, " of ", length(files))
      all_ok <- FALSE
    } else {
      log_msg("       OK: ", group, " (", length(files), ")")
    }
  }

  if (!all_ok) stop("Sub-step bundle contents incomplete. Re-run 01d/01e.")
  log_msg("")
  log_msg("All inputs verified.")
  log_msg("")
}

check_inputs()

## ============================================================================
## HELPERS
## ============================================================================

assert_same_crs <- function(r1, r2, label1, label2) {
  if (terra::crs(r1, proj = TRUE) != terra::crs(r2, proj = TRUE)) {
    stop("CRS mismatch: ", label1, " vs ", label2,
         "\n  ", label1, ": ", terra::crs(r1, proj = TRUE),
         "\n  ", label2, ": ", terra::crs(r2, proj = TRUE))
  }
}

## Canonical land mask: TRUE where canonical DEM > 0
canonical_land <- dem_canonical > 0

## -- biovars from 12 monthly normals -----------------------------------------

make_bioclim <- function(period_dir, label) {
  log_msg("  Reading normals from: ", basename(period_dir))

  months_02 <- sprintf("%02d", 1:12)
  tmin_stack <- terra::rast(file.path(period_dir, paste0("tmin_normal_", months_02, ".tif")))
  tmax_stack <- terra::rast(file.path(period_dir, paste0("tmax_normal_", months_02, ".tif")))
  rf_stack   <- terra::rast(file.path(period_dir, paste0("rf_normal_",   months_02, ".tif")))

  assert_same_crs(tmin_stack, tmax_stack, "tmin", "tmax")
  assert_same_crs(tmin_stack, rf_stack,   "tmin", "rainfall")

  log_msg("  Grid: ", terra::nrow(tmin_stack), " x ", terra::ncol(tmin_stack),
          " (", terra::ncell(tmin_stack), " cells)")
  log_msg("  Running dismo::biovars() for ", label, "...")

  tmin_mat <- terra::values(tmin_stack)
  tmax_mat <- terra::values(tmax_stack)
  rf_mat   <- terra::values(rf_stack)

  valid <- rowSums(!is.na(tmin_mat)) == 12 &
           rowSums(!is.na(tmax_mat)) == 12 &
           rowSums(!is.na(rf_mat))   == 12

  bio_mat <- matrix(NA_real_, nrow = nrow(tmin_mat), ncol = 19)
  if (sum(valid) > 0) {
    bio_mat[valid, ] <- dismo::biovars(
      prec = rf_mat[valid, , drop = FALSE],
      tmin = tmin_mat[valid, , drop = FALSE],
      tmax = tmax_mat[valid, , drop = FALSE]
    )
  }

  rm(tmin_mat, tmax_mat, rf_mat); gc(verbose = FALSE)

  bio_stack <- terra::rast(tmin_stack, nlyrs = 19)
  terra::values(bio_stack) <- bio_mat
  names(bio_stack) <- BIO_NAMES

  rm(bio_mat); gc(verbose = FALSE)
  log_msg("  Bioclim: ", sum(valid), " valid cells, 19 layers")
  bio_stack
}

## -- Climate Atlas summaries -------------------------------------------------
## Masks all output layers to canonical land footprint (DEM > 0) to enforce
## coastline authority per PIPELINE_SPEC "Footprint alignment for Track A".

make_atlas_layers <- function() {
  layers <- list()

  for (var in ATLAS_VARS) {
    months_02 <- sprintf("%02d", 1:12)
    monthly_files <- file.path(atlas_dir, paste0(var, "_", months_02, ".tif"))
    ann_file      <- file.path(atlas_dir, paste0(var, "_ann.tif"))

    if (!all(file.exists(monthly_files))) {
      stop("Climate Atlas monthly missing for: ", var)
    }

    monthly <- terra::rast(monthly_files)

    for (stat in ATLAS_SUMMARIES) {
      nm <- paste0(var, "_", stat)
      ## suppressWarnings: min/max on all-NA ocean cells warns "no non-missing
      ## arguments"; result is Inf/-Inf, cleaned up below. Expected behavior.
      r <- if (stat == "min") {
        suppressWarnings(terra::app(monthly, fun = \(x) min(x, na.rm = TRUE)))
      } else if (stat == "max") {
        suppressWarnings(terra::app(monthly, fun = \(x) max(x, na.rm = TRUE)))
      } else if (stat == "ann" && file.exists(ann_file)) {
        terra::rast(ann_file)
      } else {
        suppressWarnings(terra::app(monthly, fun = \(x) mean(x, na.rm = TRUE)))
      }
      ## min/max with na.rm=TRUE on all-NA ocean cells produces Inf/-Inf.
      ## Replace with NA so ocean stays ocean in the final stack.
      r[is.infinite(r)] <- NA
      ## Mask to canonical land footprint (DEM > 0). This removes ~298
      ## Climate Atlas "land" cells that the canonical mask treats as ocean,
      ## enforcing 01a's coastline as the single source of truth.
      r <- terra::mask(r, canonical_land, maskvalues = 0)
      names(r) <- nm
      layers[[nm]] <- r
    }
    log_msg("    ", var, ": ", length(ATLAS_SUMMARIES), " summaries")
  }

  if (length(layers) == 0) stop("No Climate Atlas layers. Check 01e outputs.")
  result <- terra::rast(layers)
  log_msg("  Climate Atlas total: ", terra::nlyr(result), " layers")
  result
}

## -- DEM at reference grid ---------------------------------------------------
## Uses canonical DEM from 01a (USGS 3DEP x HCDP rainfall footprint).
## For Track A (250m HCDP grid) no resample needed -- canonical DEM is
## already on the same grid. For Track B (~1km WorldClim) resample.

prepare_dem <- function(ref_raster) {
  if (terra::compareGeom(dem_canonical, ref_raster, stopOnError = FALSE)) {
    dem_r <- dem_canonical
  } else {
    dem_r <- terra::resample(dem_canonical, ref_raster, method = "bilinear")
  }

  names(dem_r) <- "elevation"
  ## Canonical DEM has 0 for ocean -- set to NA for stack
  dem_r[dem_r <= 0] <- NA
  log_msg("  DEM resampled to ",
          paste(round(terra::res(ref_raster), 6), collapse = " x "))
  dem_r
}

## -- Verify stack NA consistency ---------------------------------------------

verify_stack <- function(stack, stack_name) {
  na_counts <- terra::global(is.na(stack), "sum")[, 1]
  names(na_counts) <- names(stack)
  nc <- terra::ncell(stack)

  unique_na <- unique(na_counts)
  if (length(unique_na) == 1) {
    log_msg("  NA consistency: OK -- all ", terra::nlyr(stack), " layers have ",
            unique_na, " NA cells (", round(100 * unique_na / nc, 1), "%)")
  } else {
    log_msg("  WARNING: inconsistent NA counts in ", stack_name, ":")
    for (nm in names(na_counts)) {
      log_msg("    ", nm, ": ", na_counts[nm], " NAs (",
              round(100 * na_counts[nm] / nc, 1), "%)")
    }
  }
}

## -- Write stack + correlation matrix ----------------------------------------

write_stack <- function(stack, stack_name) {
  out_tif  <- file.path(OUTDIR, paste0("01_env_stack_", stack_name, ".tif"))
  out_corr <- file.path(OUTDIR, paste0("01_correlation_matrix_", stack_name, ".csv"))

  terra::writeRaster(stack, out_tif, overwrite = TRUE,
                      datatype = "FLT4S", gdal = "COMPRESS=LZW")
  log_msg("  Written: ", basename(out_tif), " (",
          terra::nlyr(stack), " layers, ",
          round(file.size(out_tif) / 1024^2, 1), " MB)")

  n_target <- 10000
  samp <- terra::spatSample(stack, size = n_target, method = "random",
                             na.rm = TRUE, as.df = TRUE)
  n_sampled <- nrow(samp)

  if (n_sampled < 100) {
    warning("Only ", n_sampled, " non-NA cells sampled for correlation in ",
            stack_name, call. = FALSE, immediate. = TRUE)
  }

  corr <- stats::cor(samp, use = "pairwise.complete.obs")
  utils::write.csv(round(corr, 4), out_corr, row.names = TRUE)
  log_msg("  Correlation: ", basename(out_corr),
          " (", n_sampled, " cells sampled)")

  upper <- corr
  upper[lower.tri(upper, diag = TRUE)] <- NA
  high <- which(abs(upper) > 0.95, arr.ind = TRUE)
  if (nrow(high) > 0) {
    log_msg("  High correlation (|r| > 0.95):")
    for (k in seq_len(nrow(high))) {
      log_msg("    ", colnames(corr)[high[k, 1]], " ~ ",
              colnames(corr)[high[k, 2]], " : ",
              round(upper[high[k, 1], high[k, 2]], 3))
    }
  }

  push_output(out_tif,  file.path("outputs", basename(out_tif)))
  push_output(out_corr, file.path("outputs", basename(out_corr)))
}

## ============================================================================
## TRACK A -- HCDP / Climate Atlas / Hawaii-specific (250m)
## ============================================================================

## -- Track A Contemporary (2002-2011) ----------------------------------------

t0 <- Sys.time()
log_msg("--- Track A Contemporary (2002-2011, 250m) ---")

bioclim_A_con <- make_bioclim(normals_dir, "Track A Contemporary")

log_msg("  Building Climate Atlas summary layers...")
atlas_layers <- make_atlas_layers()

assert_same_crs(bioclim_A_con, atlas_layers, "bioclim", "Climate Atlas")
dem_A <- prepare_dem(bioclim_A_con)
assert_same_crs(bioclim_A_con, dem_A, "bioclim", "DEM")

stack_A_con <- c(bioclim_A_con, atlas_layers, dem_A)
log_msg("  Total layers: ", terra::nlyr(stack_A_con))
verify_stack(stack_A_con, "trackA_contemporary")
write_stack(stack_A_con, "trackA_contemporary")

rm(bioclim_A_con, atlas_layers, stack_A_con, dem_A); gc(verbose = FALSE)
timings[["trackA_contemporary"]] <- as.numeric(round(difftime(Sys.time(), t0, units = "mins"), 1))
log_msg("  Time: ", timings[["trackA_contemporary"]], " min")
log_msg("")

## ============================================================================
## TRACK B -- WorldClim (global baseline, ~1km)
## ============================================================================

## -- Track B Contemporary (WorldClim v2.1, 1970-2000) ------------------------

t0 <- Sys.time()
log_msg("--- Track B Contemporary (WorldClim v2.1, ~1km) ---")

log_msg("  Extracting WorldClim v2.1 (single pass)...")
wc21_tmp <- file.path(scratch, "wc21")
dir.create(wc21_tmp, showWarnings = FALSE, recursive = TRUE)
wc21_names <- paste0("wc2.1_30s_bio_", 1:19, ".tif")
wc21_zip_paths <- paste0("wc2.1_30s_bio/", wc21_names)
utils::unzip(wc21_zip, files = wc21_zip_paths, exdir = wc21_tmp, junkpaths = TRUE)

wc21_layers <- vector("list", 19)
for (i in 1:19) {
  path_i <- file.path(wc21_tmp, wc21_names[i])
  if (!file.exists(path_i)) stop("Missing: ", wc21_names[i])
  wc21_layers[[i]] <- terra::crop(terra::rast(path_i), HAWAII_EXT)
  names(wc21_layers[[i]]) <- paste0("bio", i)
}
wc21_stack <- terra::rast(wc21_layers)
unlink(wc21_tmp, recursive = TRUE)
log_msg("  WorldClim v2.1: ", terra::nlyr(wc21_stack), " layers cropped")

dem_B_con <- prepare_dem(wc21_stack)
stack_B_con <- c(wc21_stack, dem_B_con)
log_msg("  Total layers: ", terra::nlyr(stack_B_con))
verify_stack(stack_B_con, "trackB_contemporary")
write_stack(stack_B_con, "trackB_contemporary")

wc_ref <- wc21_stack[[1]]
rm(wc21_layers, wc21_stack, dem_B_con, stack_B_con); gc(verbose = FALSE)
timings[["trackB_contemporary"]] <- as.numeric(round(difftime(Sys.time(), t0, units = "mins"), 1))
log_msg("  Time: ", timings[["trackB_contemporary"]], " min")
log_msg("")

## -- Track B Historic (WorldClim v1.4, 1960-1990) ----------------------------
## This stack also serves as the historic reference for any Track A x historic
## comparison, per decision #17 (ERA5-Land retired).

t0 <- Sys.time()
log_msg("--- Track B Historic (WorldClim v1.4, ~1km) ---")

log_msg("  Extracting WorldClim v1.4...")
wc14_tmp <- file.path(scratch, "wc14")
dir.create(wc14_tmp, showWarnings = FALSE, recursive = TRUE)
utils::unzip(wc14_zip, exdir = wc14_tmp, junkpaths = TRUE)

## v1.4 integer rescaling:
##   bio1, bio2, bio5-bio11 (temperature): stored as C x 10 -> divide by 10
##   bio4 (temperature seasonality): stored as SD computed from C*10 values,
##     then multiplied by 100 -> effectively SD(C) * 1000. Divide by 10 to
##     match v2.1 and biovars() convention of SD(C) * 100.
##   bio3 (isothermality), bio15 (precip CV): ratio*100 / CV*100 integers,
##     consistent with v2.1. Do NOT divide.
##   bio12-bio19 (precipitation): mm, no change
##
## FLAG [bio4 rescaling]: PIPELINE_SPEC says "bio4 / 100". Empirically,
## v1.4 bio4 for Hawaii is 1000-1700 while v2.1 is 100-180 -- a 10x ratio,
## not 100x. The factor of 10 arises because v1.4 computed SD from
## temperatures already stored as C*10. Dividing by 10 (not 100) makes
## v1.4 bio4 consistent with v2.1 and dismo::biovars(). If the spec
## intended /100, the resulting bio4 values (~10-17) would be 10x smaller
## than every other source. This script uses /10; flag for PM review.
TEMP_BIOS <- c(1, 2, 5, 6, 7, 8, 9, 10, 11)

wc14_layers <- vector("list", 19)
for (i in 1:19) {
  bil <- file.path(wc14_tmp, paste0("bio_", i, ".bil"))
  if (!file.exists(bil)) stop("Missing: bio_", i, ".bil")

  r <- terra::crop(terra::rast(bil), HAWAII_EXT)

  if (i %in% TEMP_BIOS) {
    r <- r / 10
  } else if (i == 4) {
    r <- r / 10  # see FLAG above
  }

  r[r < -999] <- NA
  names(r) <- paste0("bio", i)
  wc14_layers[[i]] <- r
}
wc14_stack <- terra::rast(wc14_layers)
unlink(wc14_tmp, recursive = TRUE)
log_msg("  WorldClim v1.4: ", terra::nlyr(wc14_stack), " layers, rescaled")

if (!terra::compareGeom(wc14_stack, wc_ref, stopOnError = FALSE)) {
  log_msg("  Resampling v1.4 to match v2.1 grid...")
  wc14_stack <- terra::resample(wc14_stack, wc_ref, method = "bilinear")
}

dem_B_hist <- prepare_dem(wc14_stack)
stack_B_hist <- c(wc14_stack, dem_B_hist)
log_msg("  Total layers: ", terra::nlyr(stack_B_hist))
verify_stack(stack_B_hist, "trackB_historic")
write_stack(stack_B_hist, "trackB_historic")

rm(wc14_layers, wc14_stack, wc_ref, dem_B_hist, stack_B_hist); gc(verbose = FALSE)
timings[["trackB_historic"]] <- as.numeric(round(difftime(Sys.time(), t0, units = "mins"), 1))
log_msg("  Time: ", timings[["trackB_historic"]], " min")
log_msg("")

## ============================================================================
## METADATA
## ============================================================================

log_msg("--- Writing metadata ---")

atlas_names <- character()
atlas_units <- character()
for (var in ATLAS_VARS) {
  for (stat in ATLAS_SUMMARIES) {
    nm <- paste0(var, "_", stat)
    atlas_names <- c(atlas_names, nm)
    atlas_units <- c(atlas_units, ATLAS_UNITS[var])
  }
}

meta <- rbind(
  data.frame(
    stack = "trackA_contemporary",
    layer = c(BIO_NAMES, atlas_names, "elevation"),
    source = c(rep("HCDP biovars() (Kodama 2024 + Lucas 2022)", 19),
               rep("Climate Atlas (Giambelluca et al. 2014)", length(atlas_names)),
               "Canonical DEM (USGS 3DEP x HCDP)"),
    period = c(rep("2002-2011 normals", 19),
               rep("static climatology (~2014)", length(atlas_names)),
               "static"),
    units = c(BIO_UNITS, atlas_units, "m"),
    resolution = "0.00225 deg (~250m)",
    stringsAsFactors = FALSE
  ),
  data.frame(
    stack = "trackB_contemporary",
    layer = c(BIO_NAMES, "elevation"),
    source = c(rep("WorldClim v2.1 (Fick & Hijmans 2017)", 19),
               "Canonical DEM (USGS 3DEP x HCDP)"),
    period = c(rep("1970-2000 baseline", 19), "static"),
    units = c(BIO_UNITS, "m"),
    resolution = "0.00833 deg (~1km)",
    stringsAsFactors = FALSE
  ),
  data.frame(
    stack = "trackB_historic",
    layer = c(BIO_NAMES, "elevation"),
    source = c(rep("WorldClim v1.4 (Hijmans et al. 2005)", 19),
               "Canonical DEM (USGS 3DEP x HCDP)"),
    period = c(rep("1960-1990 baseline", 19), "static"),
    units = c(BIO_UNITS, "m"),
    resolution = "0.00833 deg (~1km)",
    stringsAsFactors = FALSE
  )
)

meta_path <- file.path(OUTDIR, "01_env_stack_metadata.csv")
utils::write.csv(meta, meta_path, row.names = FALSE)
log_msg("  Metadata: ", nrow(meta), " rows across ",
        length(unique(meta$stack)), " stacks")
push_output(meta_path, "outputs/01_env_stack_metadata.csv")

## ============================================================================
## SUMMARY + LOG FILE
## ============================================================================

t_total <- as.numeric(round(difftime(Sys.time(), t_start, units = "mins"), 1))

log_msg("")
log_msg("=== Step 01 complete ===")
log_msg("Total time: ", t_total, " min")
log_msg("")

out_files <- sort(list.files(OUTDIR, pattern = "^01_(env_stack|correlation)",
                              full.names = TRUE))
for (f in out_files) {
  log_msg(sprintf("  %-55s %8.1f MB", basename(f), file.size(f) / 1024^2))
}

n_atlas <- length(atlas_names)
log_msg("")
log_msg("Stacks:")
log_msg("  trackA_contemporary -- 19 bioclim + ", n_atlas,
        " Climate Atlas + elevation (250m)")
log_msg("  trackB_contemporary -- 19 WorldClim v2.1 + elevation (~1km)")
log_msg("  trackB_historic     -- 19 WorldClim v1.4 + elevation (~1km)")
log_msg("")
log_msg("Note: Track A Historic retired (decision #17, ERA5-Land bias).")
log_msg("      Historic analyses use trackB_historic for all tracks.")
log_msg("")
log_msg("Timings:")
for (nm in names(timings)) {
  log_msg("  ", nm, ": ", timings[[nm]], " min")
}
log_msg("")
log_msg("No elevation mask applied. Masking deferred to Step 03.")

log_path <- file.path(OUTDIR, "01_step01_summary.txt")
writeLines(log_lines, log_path)
push_output(log_path, "outputs/01_step01_summary.txt")

cat("\nLog written to:", log_path, "\n")
cat("Step 01 done.\n")
